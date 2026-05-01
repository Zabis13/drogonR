/**
 *
 *  DbClientManagerSkipped.cc
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

#include "DbClientManager.h"
#include <algorithm>
// drogonR: throw / return-empty instead of abort() — CRAN forbids abort
// in package .so. These stubs are unreachable (no DB driver linked).
#include <stdexcept>
#include <stdlib.h>

using namespace drogon::orm;
using namespace drogon;

void DbClientManager::createDbClients(
    const std::vector<trantor::EventLoop *> & /*ioLoops*/)
{
    return;
}

void DbClientManager::addDbClient(const DbConfig &)
{
    LOG_FATAL << "No database is supported by drogon, please install the "
                 "database development library first.";
    // drogonR: was abort().
    throw std::runtime_error("drogon: no database driver linked");
}

bool DbClientManager::areAllDbClientsAvailable() const noexcept
{
    LOG_FATAL << "No database is supported by drogon, please install the "
                 "database development library first.";
    // drogonR: was abort(); noexcept forbids throw, return false.
    return false;
}

DbClientManager::~DbClientManager()
{
}
