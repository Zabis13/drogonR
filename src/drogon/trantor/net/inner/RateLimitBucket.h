/**
 *
 *  @file RateLimitBucket.h
 *  @author drogonR
 *
 *  drogonR patch: per-connection egress bandwidth shaping.
 *
 *  Not part of upstream Trantor. A token bucket owned by a single
 *  TcpConnectionImpl and touched only from that connection's event loop
 *  thread, so it needs no atomics and no locking.
 *
 */

#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>

namespace trantor
{
/**
 * @brief Process-wide default egress limit applied to new connections.
 *
 * drogonR patch: set once from the main thread before the server starts
 * accepting, then read from I/O threads as each connection is created.
 * Written before any reader exists, so plain loads suffice.
 */
struct RateLimitConfig
{
    size_t rate{0};   // bytes per second; 0 = unlimited
    size_t burst{0};  // bucket capacity in bytes

    static RateLimitConfig &instance()
    {
        static RateLimitConfig cfg;
        return cfg;
    }
};

/**
 * @brief Token bucket limiting how many bytes a connection may write.
 *
 * Tokens are bytes. The bucket refills continuously at @p rate bytes per
 * second up to a ceiling of @p burst bytes, so a connection that has been
 * idle may write a short burst at line speed before being held to the
 * sustained rate.
 *
 * The clock is only read when the bucket has run dry -- while tokens
 * remain, consume() is a subtraction and a comparison, which keeps the
 * unshaped fast path free of a clock_gettime() per write.
 */
class RateLimitBucket
{
  public:
    using Clock = std::chrono::steady_clock;

    RateLimitBucket() = default;

    /**
     * @param rate  sustained bytes per second; 0 disables shaping.
     * @param burst bucket capacity in bytes. Clamped to at least one
     *              refill tick's worth so the bucket cannot deadlock.
     */
    RateLimitBucket(size_t rate, size_t burst) : rate_(rate), burst_(burst)
    {
        if (rate_ == 0)
            return;
        if (burst_ < kMinBurst)
            burst_ = kMinBurst;
        tokens_ = static_cast<double>(burst_);
        last_ = Clock::now();
    }

    bool enabled() const
    {
        return rate_ != 0;
    }

    /**
     * @brief How many of the @p wanted bytes may be written right now.
     *
     * Returns 0 when the bucket is empty, in which case the caller should
     * stop writing and re-arm after delayForTokens().
     */
    size_t allowance(size_t wanted)
    {
        if (rate_ == 0)
            return wanted;
        if (tokens_ < static_cast<double>(wanted))
            refill();
        auto avail = tokens_ > 0 ? static_cast<size_t>(tokens_) : 0;
        return avail < wanted ? avail : wanted;
    }

    /**
     * @brief Account for bytes actually written.
     *
     * Only ever called with a count that allowance() permitted, so tokens_
     * cannot go negative.
     */
    void consume(size_t bytes)
    {
        if (rate_ == 0)
            return;
        tokens_ -= static_cast<double>(bytes);
        if (tokens_ < 0)
            tokens_ = 0;
    }

    /**
     * @brief Seconds to wait before a useful chunk can be written again.
     *
     * Waiting for a single byte would wake the connection thousands of
     * times a second and write a few bytes each time, so we wait for a
     * segment's worth (or the whole bucket, if it is smaller than that).
     *
     * Floored at kMinDelay so a pathologically low rate cannot spin the
     * timer queue, and capped so a caller never parks a connection for an
     * unbounded time on a single refill.
     */
    double delayForTokens() const
    {
        if (rate_ == 0)
            return 0.0;
        double target = static_cast<double>(burst_ < kMinBurst ? burst_
                                                               : kMinBurst);
        double needed = target - tokens_;
        if (needed <= 0)
            return kMinDelay;
        double delay = needed / static_cast<double>(rate_);
        if (delay < kMinDelay)
            return kMinDelay;
        return delay > kMaxDelay ? kMaxDelay : delay;
    }

  private:
    void refill()
    {
        auto now = Clock::now();
        std::chrono::duration<double> elapsed = now - last_;
        last_ = now;
        tokens_ += elapsed.count() * static_cast<double>(rate_);
        if (tokens_ > static_cast<double>(burst_))
            tokens_ = static_cast<double>(burst_);
    }

    // A bucket smaller than this cannot hold a single TCP segment, which
    // would shrink every write to a few bytes and defeat the point.
    static constexpr size_t kMinBurst = 1500;
    static constexpr double kMinDelay = 0.001;
    static constexpr double kMaxDelay = 1.0;

    size_t rate_{0};
    size_t burst_{0};
    double tokens_{0};
    Clock::time_point last_{};
};

}  // namespace trantor
