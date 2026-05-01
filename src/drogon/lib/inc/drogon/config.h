#pragma once

/* Generated for drogonR (CRAN-friendly build).
 * No DB / no Redis / no Boost. OpenSSL is detected by R configure script
 * and the corresponding macros are defined in PKG_CPPFLAGS, not here. */

#define USE_POSTGRESQL 0
#define LIBPQ_SUPPORTS_BATCH_MODE 0
#define USE_MYSQL 0
#define USE_SQLITE3 0
#define HAS_STD_FILESYSTEM_PATH 1

/* OpenSSL_FOUND / Boost_FOUND intentionally undefined here.
 * Configure script defines OpenSSL_FOUND in CPPFLAGS when TLS is enabled. */

#define COMPILATION_FLAGS ""
#define COMPILER_COMMAND ""
#define COMPILER_ID ""
#define INCLUDING_DIRS ""
