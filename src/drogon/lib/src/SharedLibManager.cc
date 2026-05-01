// drogonR: stubbed Drogon SharedLibManager.
//
// The original SharedLibManager implements hot-reload of plugin .so files
// via fork()+execvp() to invoke an external compiler. drogonR is an
// embedded HTTP server inside an R session and never registers plugin
// library paths, so HttpAppFrameworkImpl never instantiates this class
// (the make_unique<SharedLibManager>(...) call is gated on
// !libFilePaths_.empty()).
//
// We replace the implementation with a stub so the .o no longer pulls
// in `_exit`, `fork`, `execvp` or `waitpid` symbols, which CRAN flags
// under "Writing portable packages".

#include "SharedLibManager.h"

namespace drogon
{
SharedLibManager::SharedLibManager(const std::vector<std::string> &libPaths,
                                   const std::string &outputPath)
    : libPaths_(libPaths), outputPath_(outputPath)
{
}

SharedLibManager::~SharedLibManager() = default;

void SharedLibManager::managerLibs()
{
}

void *SharedLibManager::compileAndLoadLib(const std::string & /*sourceFile*/,
                                          void *oldHld)
{
    return oldHld;
}

void *SharedLibManager::loadLib(const std::string & /*soFile*/, void *oldHld)
{
    return oldHld;
}

bool SharedLibManager::shouldCompileLib(const std::string & /*soFile*/,
                                        const struct stat & /*sourceStat*/)
{
    return false;
}
}  // namespace drogon
