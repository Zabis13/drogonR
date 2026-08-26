## Submission (0.1.9)

This release fixes the clang trunk / libc++ build failure reported on the
CRAN check page:

```
drogon/trantor/utils/ConcurrentTaskQueue.h:85:10: error:
  no type named 'atomic_bool' in namespace 'std'
```

Recent libc++ no longer pulls `<atomic>` in transitively, so an explicit
`#include <atomic>` was added to every bundled Drogon/Trantor source that
uses `std::atomic*` (8 files). No R-level changes.

drogonR provides an R interface to the Drogon C++ HTTP server framework,
intended as a high-performance alternative to plumber for serving REST
APIs from R. The Drogon, Trantor and JsonCpp sources are bundled in
`src/drogon/` and compiled statically; no external installation of
Drogon is required.

## R CMD check results

0 errors | 0 warnings | N notes

Expected NOTEs:

* **installed package size**: the package bundles the Drogon HTTP
  framework, the Trantor network library and JsonCpp. The size of the
  installed shared object is inherent to the bundled C++ codebase.

* **GNU make is a SystemRequirements**: declared in DESCRIPTION; required
  by the bundled build.

* **Authors with role 'cph' but no obvious copyright**: the `cph`
  entries (An Tao, Shuo Chen, Baptiste Lepilleur, JsonCpp Contributors)
  are upstream authors of the bundled libraries (Drogon/Trantor, the
  Muduo library on which Trantor is based, and JsonCpp respectively).
  Their copyright notices are preserved in the bundled source tree
  (see the LICENSE files under `src/drogon/`).

## Build time

Installation requires compiling vendored Drogon C++ HTTP framework
(~110 translation units). Expected install time: 5-7 min on Windows,
2-3 min on Linux. This is known and unavoidable without pre-built binaries.

## Test environments

* Local: Linux (Ubuntu 24.04), R 4.3.3, GCC 13.3.0

## Downstream dependencies

None.
