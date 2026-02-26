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

#ifdef __cplusplus
extern "C" {
#endif

// Most functions enqueue work onto a libp2p worker thread and return quickly.
// The provided callback delivers the actual result (or error) and is required.

// Return codes indicate whether the request was accepted/enqueued.
// Operation success/failure is reported asynchronously via the callback.
#define RET_OK 0
#define RET_ERR 1
#define RET_MISSING_CALLBACK 2

// Callback data ownership:
// - msg and data are only valid for the duration of the callback.
// - msg is not guaranteed to be null-terminated; use (msg, len).
// - Callbacks are invoked on the libp2p worker thread; avoid blocking.

typedef void (*Libp2pCallback)(int callerRet, const char *msg, size_t len,
                               void *userData);

typedef void (*Libp2pBufferCallback)(int callerRet, const uint8_t *data,
                                     size_t dataLen, const char *msg,
                                     size_t len, void *userData);

// === Basic Types and Enums ===

// Opaque handle for a libp2p instance
// libp2p instance (created by libp2p_new).
typedef struct libp2p_ctx libp2p_ctx_t;

// stream handle returned by dial/mix_dial callbacks.
typedef struct libp2p_stream libp2p_stream_t;

// Curve25519 private/public key bytes used by the mix protocol.
typedef struct {
  uint8_t bytes[32];
} libp2p_curve25519_key_t;

// Compressed secp256k1 public key bytes (33 bytes, including prefix).
typedef struct {
  uint8_t bytes[33];
} libp2p_secp256k1_pubkey_t;

// Private key scheme identifier for libp2p_private_key_t.
typedef uint32_t libp2p_pk_scheme;
enum {
  LIBP2P_PK_RSA = 0,
  LIBP2P_PK_ED25519 = 1,
  LIBP2P_PK_SECP256K1 = 2,
  LIBP2P_PK_ECDSA = 3,
};

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

typedef uint32_t Libp2pMuxer;

enum {
  LIBP2P_MUXER_MPLEX = 0,
  LIBP2P_MUXER_YAMUX = 1,
};

// === Data Structures ===

// Kademlia bootstrap node entry (peer ID + multiaddrs).
// The arrays are read-only for the duration of the call that uses them.
typedef struct libp2p_bootstrap_node {
  const char *peerId;
  const char **multiaddrs;
  size_t multiaddrsLen;
} libp2p_bootstrap_node_t;

// Opaque private key bytes; interpretation depends on libp2p_pk_scheme.
typedef struct libp2p_private_key {
  void *data;
  size_t dataLen;
} libp2p_private_key_t;

typedef struct {
  const uint8_t *value;
  size_t valueLen;
  const char *time;
  size_t timeLen;
} libp2p_kad_entry_record_t;

// Return nonzero to accept a key/value record, 0 to reject.
typedef int (*KadEntryValidator)(const uint8_t *key, size_t keyLen,
                                 libp2p_kad_entry_record_t record,
                                 void *userData);

// Return selected record index in [0, recordsLen), or -1 to reject.
typedef int (*KadEntrySelector)(const uint8_t *key, size_t keyLen,
                                const libp2p_kad_entry_record_t *records,
                                size_t recordsLen, void *userData);
typedef struct {
  // Enable/disable gossipsub (default on).
  int mount_gossipsub;

  // If nonzero, deliver published messages to self subscribers too.
  int gossipsub_trigger_self;

  // Enable/disable Kademlia DHT (default on).
  int mount_kad;

  // Enable/disable mix protocol support (default off).
  int mount_mix;

  // Enable Kademlia Discovery  (default off).
  int mount_kad_discovery;

  // DNS resolver address used by name resolution (e.g. "1.1.1.1:53").
  const char *dns_resolver;

  // Optional list of listen addresses.
  const char **addrs;
  // Number of entries in addrs.
  size_t addrsLen;

  // Multiplexer to use
  Libp2pMuxer muxer;

  // Optional list of Kademlia bootstrap nodes.
  const libp2p_bootstrap_node_t *kad_bootstrap_nodes;
  // Number of entries in kad_bootstrap_nodes.
  size_t kad_bootstrap_nodes_len;
  // Optional Kademlia value validator callback.
  KadEntryValidator kad_validator;
  // Optional Kademlia value selector callback.
  KadEntrySelector kad_selector;
  // Opaque user data passed to kad_validator/kad_selector callbacks.
  void *kad_user_data;

  // Optional private key bytes (only used if is not nil).
  libp2p_private_key_t priv_key;

  // Maximum number of connections (in + out)
  int max_connections;
  // Maximum number of incoming connections
  int max_in;
  // Maximum number of outgoing connections
  int max_out;
  // Maximum number of connections per peer
  int max_conns_per_peer;

} libp2p_config_t;

typedef struct {
  char *peerId;
  const char **addrs;
  size_t addrsLen;
} Libp2pPeerInfo;

// Service descriptor returned by Kademlia discovery.
// Fields are only valid for the duration of the callback; copy if needed.
typedef struct {
  char *id;
  const uint8_t *data;
  size_t dataLen;
} Libp2pServiceInfo;

// Extended peer record returned by Kademlia discovery.
// All fields/arrays are only valid for the duration of the callback; copy if
// needed.
typedef struct {
  char *peerId;
  uint64_t seqNo;
  const char **addrs;
  size_t addrsLen;
  const Libp2pServiceInfo *services;
  size_t servicesLen;
} Libp2pExtendedPeerRecord;

// === Callbacks ===

typedef void (*PubsubTopicHandler)(const char *topic, uint8_t *data, size_t len,
                                   void *userData);

// PeerInfoCallback receives a Libp2pPeerInfo that is only valid for the
// duration of the callback. All fields are freed immediately after the
// callback returns; copy any data you need to keep.
typedef void (*PeerInfoCallback)(int callerRet, const Libp2pPeerInfo *info,
                                 const char *msg, size_t len, void *userData);

typedef void (*RandomRecordsCallback)(int callerRet,
                                      const Libp2pExtendedPeerRecord *records,
                                      size_t recordsLen, const char *msg,
                                      size_t len, void *userData);

// peerIds is only valid during the callback; copy if needed.
typedef void (*PeersCallback)(int callerRet, const char **peerIds,
                              size_t peerIdsLen, const char *msg, size_t len,
                              void *userData);

// ConnectionCallback returns a stream handle that must be released with
// libp2p_stream_release when no longer needed.
typedef void (*ConnectionCallback)(int callerRet, libp2p_stream_t *conn,
                                   const char *msg, size_t len, void *userData);

// providers is only valid during the callback; copy if needed.
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

// topic/data are only valid during the handler call; copy if needed.
typedef void TopicHandler(const char *topic, uint8_t *data, size_t len,
                          void *userData);

// === Utility / Key APIs ===

// callback receives the CID string in msg (not null-terminated).
// data is copied during this call; it can be freed once the function returns.
int libp2p_create_cid(uint32_t version, const char *multicodec,
                      const char *hash, const uint8_t *data, size_t dataLen,
                      Libp2pCallback callback, void *userData);

// callback receives raw private key bytes for the requested scheme.
// The returned buffer is only valid during the callback; copy if needed.
int libp2p_new_private_key(libp2p_pk_scheme scheme,
                           Libp2pBufferCallback callback, void *userData);

// Creates a new libp2p_config_t with default values
libp2p_config_t libp2p_new_default_config();

// === Lifecycle APIs ===

// Creates a new libp2p node instance from config; the node is not started
// until libp2p_start is called.
libp2p_ctx_t *libp2p_new(const libp2p_config_t *config, Libp2pCallback callback,
                         void *userData);

// Destroys the node and releases all resources associated with ctx.
int libp2p_destroy(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

// TODO: might not be needed
void libp2p_set_event_callback(libp2p_ctx_t *ctx, Libp2pCallback callback,
                               void *userData);

int libp2p_start(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

int libp2p_stop(libp2p_ctx_t *ctx, Libp2pCallback callback, void *userData);

// === Connection APIs ===

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

// === Stream APIs ===

int libp2p_dial(libp2p_ctx_t *ctx, const char *peerId, const char *proto,
                ConnectionCallback callback, void *userData);

// Read callbacks receive a buffer that is freed immediately after the callback.
int libp2p_stream_readExactly(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                              size_t dataLen, Libp2pBufferCallback callback,
                              void *userData);

int libp2p_stream_readLp(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                         int64_t maxSize, Libp2pBufferCallback callback,
                         void *userData);

// Write calls copy the input buffer before enqueueing; data can be freed after
// the function returns.
int libp2p_stream_write(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                        const uint8_t *data, size_t dataLen,
                        Libp2pCallback callback, void *userData);

int libp2p_stream_writeLp(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                          const uint8_t *data, size_t dataLen,
                          Libp2pCallback callback, void *userData);

int libp2p_stream_close(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                        Libp2pCallback callback, void *userData);

// Closes the stream and then sends EOF to the remote side.
int libp2p_stream_closeWithEOF(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                               Libp2pCallback callback, void *userData);

// Releases the local stream handle. After this, conn must not be used again.
// You usually call close/closeWithEOF first, then release.
int libp2p_stream_release(libp2p_ctx_t *ctx, libp2p_stream_t *conn,
                          Libp2pCallback callback, void *userData);

// === Pubsub APIs ===

// TODO: pubsub parameters
// TODO: gossipsub parameters
// TODO: topic parameters
// TODO: observers
// TODO: subscription validator

int libp2p_gossipsub_publish(libp2p_ctx_t *ctx, const char *topic,
                             uint8_t *data, size_t dataLen,
                             Libp2pCallback callback, void *userData);

// topicHandler runs on the libp2p worker thread; topic/data are valid only
// for the duration of the handler call.
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

// === Kademlia APIs ===

int libp2p_kad_find_node(libp2p_ctx_t *ctx, const char *peerId,
                         PeersCallback callback, void *userData);

int libp2p_kad_put_value(libp2p_ctx_t *ctx, const uint8_t *key, size_t keyLen,
                         const uint8_t *value, size_t valueLen,
                         Libp2pCallback callback, void *userData);

int libp2p_kad_get_value(libp2p_ctx_t *ctx, const uint8_t *key, size_t keyLen,
                         int quorumOverride, Libp2pBufferCallback callback,
                         void *userData);

int libp2p_kad_add_provider(libp2p_ctx_t *ctx, const char *cid,
                            Libp2pCallback callback, void *userData);

int libp2p_kad_start_providing(libp2p_ctx_t *ctx, const char *cid,
                               Libp2pCallback callback, void *userData);

int libp2p_kad_stop_providing(libp2p_ctx_t *ctx, const char *cid,
                              Libp2pCallback callback, void *userData);

int libp2p_kad_get_providers(libp2p_ctx_t *ctx, const char *cid,
                             GetProvidersCallback callback, void *userData);

int libp2p_kad_random_records(libp2p_ctx_t *ctx, RandomRecordsCallback callback,
                              void *userData);

// === Mix APIs ===

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

// Registers how the exit-layer reads payloads for the given proto.
// behavior + size_param:
// - LIBP2P_MIX_READ_EXACTLY: read exactly size_param bytes
// - LIBP2P_MIX_READ_LP: read length-prefixed frames up to size_param bytes
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

// callback receives a buffer valid only during its execution
int libp2p_public_key(libp2p_ctx_t *ctx, Libp2pBufferCallback callback,
                      void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __libp2p__ */
