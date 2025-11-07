/**
 * libp2p.h - C Interface for nim-libp2p
 *
 * This header provides the public API for libp2p
 *
 * TODO: add description
 */
#ifndef __libp2p__
#define __libp2p__

#include <stddef.h>
#include <stdint.h>

// The possible returned values for the functions that return int
#define RET_OK 0
#define RET_ERR 1
#define RET_MISSING_CALLBACK 2

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*Libp2pCallback)(int callerRet, const char *msg, size_t len,
                               void *userData);

void *libp2p_new(Libp2pCallback callback, void *userData);

int libp2p_destroy(void *ctx, Libp2pCallback callback, void *userData);

void libp2p_set_event_callback(void *ctx, Libp2pCallback callback,
                               void *userData);

int libp2p_hello(void *ctx, Libp2pCallback callback, void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __libp2p__ */