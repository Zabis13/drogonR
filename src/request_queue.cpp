// drogonR — request queue.
//
// SPSC pattern via trantor::LockFreeQueue would be ideal, but Drogon
// uses a thread pool for I/O, so we have multiple producers. We use
// a plain std::deque + mutex for now: contention is minimal because
// every push is followed by a single byte to the wakeup pipe and the
// dispatcher drains the queue in one shot.

#include "r_bridge.h"
#include "socket_compat.h"

#include <deque>
#include <mutex>
#include <atomic>

namespace drogonR {

namespace {
std::deque<PendingRequest> g_queue;
std::mutex                 g_queueMutex;

std::atomic<int>         g_wakeWriteFd{-1};
std::atomic<int>         g_wakeReadFd{-1};
// 0 means "unbounded" — used during teardown / before server_start.
std::atomic<std::size_t> g_queueMaxSize{0};
} // namespace

void setQueueMaxSize(std::size_t n) {
    g_queueMaxSize.store(n);
}

// Called from the dispatcher (main R thread) at server start.
void initQueueWakeup(int readFd, int writeFd) {
    g_wakeReadFd.store(readFd);
    g_wakeWriteFd.store(writeFd);
}

void resetQueueWakeup() {
    g_wakeReadFd.store(-1);
    g_wakeWriteFd.store(-1);
    std::lock_guard<std::mutex> lock(g_queueMutex);
    g_queue.clear();
}

int queueWakeReadFd() {
    return g_wakeReadFd.load();
}

bool enqueueRequest(PendingRequest &&req) {
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        std::size_t cap = g_queueMaxSize.load();
        if (cap > 0 && g_queue.size() >= cap) {
            return false;  // caller responds 503; req is left untouched.
        }
        g_queue.emplace_back(std::move(req));
    }
    notifyDispatcher();
    return true;
}

void notifyDispatcher() {
    // Best-effort: if the pipe is full the dispatcher will see the
    // queue anyway on its next drain.
    writeWakeByte(g_wakeWriteFd.load());
}

// Drains everything currently queued and returns it to the caller in
// one move. The dispatcher then iterates outside the lock so R callbacks
// don't hold the mutex.
std::deque<PendingRequest> drainQueue() {
    std::deque<PendingRequest> out;
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        out.swap(g_queue);
    }
    return out;
}

// Drains and discards the wakeup byte(s). Called from the fd callback.
void drainWakePipe() {
    drainWakeBytes(g_wakeReadFd.load());
}

} // namespace drogonR
