/**
 *
 *  RedisClientSkipped.cc
 *  An Tao
 *
 *  Copyright 2018, An Tao.  All rights reserved.
 *  https://github.com/an-tao/drogon
 *  Use of this source code is governed by a MIT license
 *  that can be found in the License file.
 *
 *  Drogon
 *
 */

#include "drogon/nosql/RedisResult.h"
#include "trantor/utils/Logger.h"
// drogonR: throw / return-empty instead of abort() — CRAN forbids abort
// in package .so. These stubs are unreachable (hiredis not linked).
#include <stdexcept>

namespace drogon
{
namespace nosql
{
std::string RedisResult::getStringForDisplaying() const noexcept
{
    LOG_FATAL << "Redis is not supported by drogon, please install the "
                 "hiredis library first.";
    // drogonR: was abort(); noexcept forbids throw, return empty.
    return {};
}

std::string RedisResult::getStringForDisplayingWithIndent(
    size_t /*indent*/) const noexcept
{
    LOG_FATAL << "Redis is not supported by drogon, please install the "
                 "hiredis library first.";
    // drogonR: was abort(); noexcept forbids throw, return empty.
    return {};
}

std::string RedisResult::asString() const noexcept(false)
{
    LOG_FATAL << "Redis is not supported by drogon, please install the "
                 "hiredis library first.";
    // drogonR: was abort().
    throw std::runtime_error("drogon: hiredis not linked");
}

RedisResultType RedisResult::type() const noexcept
{
    LOG_FATAL << "Redis is not supported by drogon, please install the "
                 "hiredis library first.";
    // drogonR: was abort(); noexcept forbids throw, return kNil sentinel.
    return RedisResultType::kNil;
}

std::vector<RedisResult> RedisResult::asArray() const noexcept(false)
{
    LOG_FATAL << "Redis is not supported by drogon, please install the "
                 "hiredis library first.";
    // drogonR: was abort().
    throw std::runtime_error("drogon: hiredis not linked");
}

long long RedisResult::asInteger() const noexcept(false)
{
    LOG_FATAL << "Redis is not supported by drogon, please install the "
                 "hiredis library first.";
    // drogonR: was abort().
    throw std::runtime_error("drogon: hiredis not linked");
}

bool RedisResult::isNil() const noexcept
{
    LOG_FATAL << "Redis is not supported by drogon, please install the "
                 "hiredis library first.";
    // drogonR: was abort(); noexcept forbids throw, return true (is nil).
    return true;
}
}  // namespace nosql
}  // namespace drogon
