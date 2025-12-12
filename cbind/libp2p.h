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

typedef void (*PubsubTopicHandler)(const char *topic, uint8_t *data, size_t len,
                                   void *userData);

typedef struct {
  char *peerId;
  const char **addrs;
  size_t addrsLen;
} Libp2pPeerInfo;

// PeerInfoCallback receives ownership of a Libp2pPeerInfo for the duration of
// the call. The data is freed immediately after the callback returns; copy it
// if you need it later.
typedef void (*PeerInfoCallback)(int callerRet, const Libp2pPeerInfo *info,
                                 const char *msg, size_t len, void *userData);
// Opaque handle for a libp2p instance
typedef struct libp2p_ctx libp2p_ctx_t;

typedef void (*ConnectedPeersCallback)(int callerRet, const char **peerIds,
                                       size_t peerIdsLen, const char *msg,
                                       size_t len, void *userData);

typedef uint32_t Direction;

enum {
  Direction_In = 0,
  Direction_Out = 1,
};

/*
typedef struct {
  uint8_t *data;
  size_t data_len;

  uint8_t *seqno;
  size_t seqno_len;

  char *topic;

  uint8_t *signature;
  size_t signature_len;

  uint8_t *key;
  size_t key_len;

  const char *fromPeer;
} Message;

typedef uint32_t ValidationResult;

enum {
  ValidationResult_Accept = 0,
  ValidationResult_Reject = 1,
  ValidationResult_Ignore = 2
};

typedef ValidationResult ValidatorHandler(const char *topic, Message msg);
*/

typedef void TopicHandler(const char *topic, uint8_t *data, size_t len,
                          void *userData);

libp2p_ctx_t *libp2p_new(Libp2pCallback callback, void *userData);

int libp2p_destroy(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

void libp2p_set_event_callback(libp2p_ctx_t *ctx, Libp2pCallback callback,
                               void *userData);

int libp2p_start(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

int libp2p_stop(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

int libp2p_connect(libp2p_ctx_t *ctx, const char *peerId, const char **multiaddrs,
                   size_t multiaddrsLen, int64_t timeoutMs,
                   Libp2pCallback callback, void *userData);

int libp2p_disconnect(libp2p_ctx_t *ctx, const char *peerId, Libp2pCallback callback,
                      void *userData);

int libp2p_peerinfo(libp2p_ctx_t *ctx, PeerInfoCallback callback, void *userData);

int libp2p_connected_peers(libp2p_ctx_t *ctx, Direction dir,
                           ConnectedPeersCallback callback, void *userData);

// TODO: pubsub parameters
// TODO: gossipsub parameters
// TODO: topic parameters
// TODO: observers
// TODO: subscription validator

int libp2p_gossipsub_publish(libp2p_ctx_t *ctx, const char *topic, uint8_t *data,
                             size_t dataLen, Libp2pCallback callback,
                             void *userData);

int libp2p_gossipsub_subscribe(libp2p_ctx_t *ctx, const char *topic,
                               TopicHandler topicHandler,
                               Libp2pCallback callback, void *userData);

int libp2p_gossipsub_unsubscribe(libp2p_ctx_t *ctx, const char *topic,
                                 TopicHandler topicHandler,
                                 Libp2pCallback callback, void *userData);

/*
int libp2p_gossipsub_add_validator(libp2p_ctx_t *ctx, const char **topics,
  size_t topicsLen, ValidatorHandler hook,
  Libp2pCallback callback, void *userData);

int libp2p_gossipsub_remove_validator(libp2p_ctx_t *ctx, const char **topics,
     size_t topicsLen, ValidatorHandler hook,
     Libp2pCallback callback, void *userData);
*/
#ifdef __cplusplus
}
#endif

#endif /* __libp2p__ */
