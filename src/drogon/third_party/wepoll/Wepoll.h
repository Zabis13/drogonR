/* drogonR shim: trantor sources include "Wepoll.h" (capital W);
 * the upstream header ships as "wepoll.h". Avoids patching trantor. */
#ifndef DROGONR_WEPOLL_SHIM_H_
#define DROGONR_WEPOLL_SHIM_H_
#include "wepoll.h"
#endif
