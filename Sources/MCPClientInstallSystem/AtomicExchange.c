#if defined(__linux__)
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#elif defined(__APPLE__)
#include <stdio.h>
#endif

#include "MCPClientInstallSystem.h"

int mcp_atomic_exchange(const char *first_path, const char *second_path) {
#if defined(__linux__)
    return renameat2(AT_FDCWD, first_path, AT_FDCWD, second_path, RENAME_EXCHANGE);
#elif defined(__APPLE__)
    return renamex_np(first_path, second_path, RENAME_SWAP);
#else
    (void)first_path;
    (void)second_path;
    return -1;
#endif
}
