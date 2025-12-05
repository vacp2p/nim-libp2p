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

typedef void TopicHandler(const char *topic, uint8_t *data, size_t len);

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

int libp2p_peerinfo(void *ctx, PeerInfoCallback callback, void *userData);

// TODO: pubsub parameters
// TODO: gossipsub parameters
// TODO: topic parameters
// TODO: observers
// TODO: subscription validator

int libp2p_gossipsub_publish(void *ctx, const char *topic, uint8_t *data,
                             size_t dataLen, unsigned int timeoutMs,
                             Libp2pCallback callback, void *userData);

int libp2p_gossipsub_subscribe(void *ctx, const char *topic,
                               TopicHandler topicHandler,
                               Libp2pCallback callback, void *userData);

int libp2p_gossipsub_unsubscribe(void *ctx, const char *topic,
                                 TopicHandler topicHandler,
                                 Libp2pCallback callback, void *userData);

/*
int libp2p_gossipsub_add_validator(void *ctx, const char **topics,
  size_t topicsLen, ValidatorHandler hook,
  Libp2pCallback callback, void *userData);

int libp2p_gossipsub_remove_validator(void *ctx, const char **topics,
     size_t topicsLen, ValidatorHandler hook,
     Libp2pCallback callback, void *userData);
*/
#ifdef __cplusplus
}
#endif

#endif /* __libp2p__ */
