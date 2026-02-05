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

typedef struct {
  uint8_t bytes[32];
} libp2p_curve25519_key_t;

typedef struct {
  uint8_t bytes[33];
} libp2p_secp256k1_pubkey_t;

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*Libp2pCallback)(int callerRet, const char *msg, size_t len,
                               void *userData);

typedef void (*Libp2pBufferCallback)(int callerRet, const uint8_t *data,
                                     size_t dataLen, const char *msg,
                                     size_t len, void *userData);

enum {
  LIBP2P_CFG_GOSSIPSUB = 1 << 0,
  LIBP2P_CFG_GOSSIPSUB_TRIGGER_SELF = 1 << 1,
  LIBP2P_CFG_KAD = 1 << 2,
  LIBP2P_CFG_KAD_DISCOVERY = 1 << 3,
  LIBP2P_CFG_DNS_RESOLVER = 1 << 4,
  LIBP2P_CFG_KAD_BOOTSTRAP_NODES = 1 << 5,
  LIBP2P_CFG_PRIVATE_KEY = 1 << 6,
  LIBP2P_CFG_MIX = 1 << 7,
};

typedef struct libp2p_bootstrap_node {
  const char *peerId;
  const char **multiaddrs;
  size_t multiaddrsLen;
} libp2p_bootstrap_node_t;

typedef uint32_t libp2p_pk_scheme;
enum {
  LIBP2P_PK_RSA = 0,
  LIBP2P_PK_ED25519 = 1,
  LIBP2P_PK_SECP256K1 = 2,
  LIBP2P_PK_ECDSA = 3,
};

typedef struct libp2p_private_key {
  void *data;
  size_t dataLen;
} libp2p_private_key_t;

typedef struct {
  uint32_t flags;
  int mount_gossipsub;
  int gossipsub_trigger_self;
  int mount_kad;
  int mount_mix;
  int mix_index;
  int mix_nodes_len;
  const char *mix_node_info_path;
  int mount_kad_discovery;
  const char *dns_resolver;
  const libp2p_bootstrap_node_t *kad_bootstrap_nodes;
  size_t kad_bootstrap_nodes_len;
  libp2p_private_key_t priv_key;
} libp2p_config_t;

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

typedef struct {
  char *id;
  const uint8_t *data;
  size_t dataLen;
} Libp2pServiceInfo;

typedef struct {
  char *peerId;
  uint64_t seqNo;
  const char **addrs;
  size_t addrsLen;
  const Libp2pServiceInfo *services;
  size_t servicesLen;
} Libp2pExtendedPeerRecord;

typedef void (*RandomRecordsCallback)(int callerRet,
                                      const Libp2pExtendedPeerRecord *records,
                                      size_t recordsLen, const char *msg,
                                      size_t len, void *userData);

// Opaque handle for a libp2p instance
typedef struct libp2p_ctx libp2p_ctx_t;

typedef void (*PeersCallback)(int callerRet, const char **peerIds,
                              size_t peerIdsLen, const char *msg, size_t len,
                              void *userData);

typedef struct libp2p_stream libp2p_stream_t;

typedef void (*ConnectionCallback)(int callerRet, libp2p_stream_t *conn,
                                   const char *msg, size_t len, void *userData);

typedef struct libp2p_stream libp2p_stream_t;

typedef uint32_t Direction;

enum {
  Direction_In = 0,
  Direction_Out = 1,
};

typedef uint32_t Libp2pMixReadBehavior;

enum {
  LIBP2P_MIX_READ_EXACTLY = 0,
  LIBP2P_MIX_READ_LP = 1,
};

typedef void (*GetProvidersCallback)(int callerRet,
                                     const Libp2pPeerInfo *providers,
                                     size_t providersLen, const char *msg,
                                     size_t len, void *userData);

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

int libp2p_create_cid(uint32_t version, const char *multicodec,
                      const char *hash, const uint8_t *data, size_t dataLen,
                      Libp2pCallback callback, void *userData);

int libp2p_new_private_key(libp2p_pk_scheme scheme, Libp2pBufferCallback callback, void *userData);

libp2p_ctx_t *libp2p_new(const libp2p_config_t *config,
                         Libp2pCallback callback, void *userData);

int libp2p_destroy(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

void libp2p_set_event_callback(libp2p_ctx_t *ctx, Libp2pCallback callback,
                               void *userData);

int libp2p_start(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

int libp2p_stop(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

int libp2p_connect(libp2p_ctx_t *ctx, const char *peerId,
                   const char **multiaddrs, size_t multiaddrsLen,
                   int64_t timeoutMs, Libp2pCallback callback, void *userData);

int libp2p_disconnect(libp2p_ctx_t *ctx, const char *peerId,
                      Libp2pCallback callback, void *userData);

int libp2p_peerinfo(libp2p_ctx_t *ctx, PeerInfoCallback callback,
                    void *userData);

int libp2p_connected_peers(libp2p_ctx_t *ctx, Direction dir,
                           PeersCallback callback, void *userData);

// TODO: libp2p_ping

int libp2p_dial(libp2p_ctx_t *ctx, const char *peerId, const char *proto,
                ConnectionCallback callback, void *userData);

void libp2p_mix_generate_priv_key(libp2p_curve25519_key_t *outKey);

void libp2p_mix_public_key(libp2p_curve25519_key_t inKey,
                           libp2p_curve25519_key_t *outKey);

int libp2p_mix_dial(libp2p_ctx_t *ctx, const char *peerId,
                    const char *multiaddr, const char *proto,
                    ConnectionCallback callback, void *userData);

int libp2p_mix_dial_with_reply(libp2p_ctx_t *ctx, const char *peerId,
                               const char *multiaddr, const char *proto,
                               int expect_reply, uint8_t num_surbs,
                               ConnectionCallback callback, void *userData);

int libp2p_mix_register_dest_read_behavior(libp2p_ctx_t *ctx, const char *proto,
                                           Libp2pMixReadBehavior behavior,
                                           uint32_t size_param,
                                           Libp2pCallback callback,
                                           void *userData);

int libp2p_mix_set_node_info(libp2p_ctx_t *ctx, const char *multiaddr,
                             libp2p_curve25519_key_t mix_priv_key,
                             Libp2pCallback callback, void *userData);

int libp2p_mix_nodepool_add(libp2p_ctx_t *ctx, const char *peerId,
                            const char *multiaddr,
                            libp2p_curve25519_key_t mix_pub_key,
                            libp2p_secp256k1_pubkey_t libp2p_pub_key,
                            Libp2pCallback callback, void *userData);

int libp2p_public_key(libp2p_ctx_t *ctx, Libp2pBufferCallback callback,
                      void *userData);

int libp2p_stream_close(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                        Libp2pCallback callback, void *userData);

int libp2p_stream_closeWithEOF(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                               Libp2pCallback callback, void *userData);

int libp2p_stream_release(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                          Libp2pCallback callback, void *userData);

int libp2p_dial(libp2p_ctx_t *ctx, const char *peerId, const char *proto,
                ConnectionCallback callback, void *userData);

int libp2p_stream_readExactly(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                              size_t dataLen, Libp2pBufferCallback callback,
                              void *userData);

int libp2p_stream_readLp(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                         int64_t maxSize, Libp2pBufferCallback callback,
                         void *userData);

int libp2p_stream_write(libp2p_ctx_t *ctx, libp2p_stream_t *conn, uint8_t *data,
                        size_t dataLen, Libp2pCallback callback,
                        void *userData);

int libp2p_stream_writeLp(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                          uint8_t *data, size_t dataLen,
                          Libp2pCallback callback, void *userData);

int libp2p_stream_close(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                        Libp2pCallback callback, void *userData);

int libp2p_stream_closeWithEOF(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                               Libp2pCallback callback, void *userData);

int libp2p_stream_release(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                          Libp2pCallback callback, void *userData);

// TODO: pubsub parameters
// TODO: gossipsub parameters
// TODO: topic parameters
// TODO: observers
// TODO: subscription validator

int libp2p_gossipsub_publish(libp2p_ctx_t *ctx, const char *topic,
                             uint8_t *data, size_t dataLen,
                             Libp2pCallback callback, void *userData);

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

int libp2p_find_node(void *ctx, const char *peerId, PeersCallback callback,
                     void *userData);

int libp2p_put_value(void *ctx, const uint8_t *key, size_t keyLen,
                     const uint8_t *value, size_t valueLen,
                     Libp2pCallback callback, void *userData);

int libp2p_get_value(void *ctx, const uint8_t *key, size_t keyLen,
                     int quorumOverride, Libp2pBufferCallback callback,
                     void *userData);

int libp2p_add_provider(void *ctx, const char *cid, Libp2pCallback callback,
                        void *userData);

int libp2p_start_providing(void *ctx, const char *cid, Libp2pCallback callback,
                           void *userData);

int libp2p_stop_providing(void *ctx, const char *cid, Libp2pCallback callback,
                          void *userData);

int libp2p_get_providers(void *ctx, const char *cid,
                         GetProvidersCallback callback, void *userData);

int libp2p_random_records(void *ctx, RandomRecordsCallback callback,
                          void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __libp2p__ */
