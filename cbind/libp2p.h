/**
 * libp2p.h - C Interface for nim-libp2p
 *
 * This header provides the public API for libp2p
 *
 * Copyright (c) 2025 Status Research & Development GmbH
 * Licensed under either of
 * -  Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
 * - MIT license ([LICENSE-MIT](LICENSE-MIT))
 * at your option.
 * This file may not be copied, modified, or distributed except according to
 * those terms.
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

int libp2p_start(void *ctx, Libp2pCallback callback, void *userData);

int libp2p_stop(void *ctx, Libp2pCallback callback, void *userData);

int libp2p_connect(void *ctx, const char *peerId, const char **multiaddrs,
                   size_t multiaddrsLen, int64_t timeoutMs,
                   Libp2pCallback callback, void *userData);

int libp2p_disconnect(void *ctx, const char *peerId, Libp2pCallback callback,
                      void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __libp2p__ */