#ifndef CR4_PRIVATE_XPC_H
#define CR4_PRIVATE_XPC_H

#include <xpc/xpc.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"

// iOS SDK 把这些标成 unavailable，越狱进程仍可链接 libxpc。
XPC_EXPORT xpc_connection_t xpc_connection_create_mach_service(const char *name, dispatch_queue_t targetq, uint64_t flags);

#ifndef XPC_CONNECTION_MACH_SERVICE_LISTENER
#define XPC_CONNECTION_MACH_SERVICE_LISTENER (1 << 0)
#endif
#ifndef XPC_CONNECTION_MACH_SERVICE_PRIVILEGED
#define XPC_CONNECTION_MACH_SERVICE_PRIVILEGED (1 << 1)
#endif

#pragma clang diagnostic pop
#endif
