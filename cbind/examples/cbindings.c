#include "../../cbind/libp2p.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CID_BUF_SIZE 128

// Shared synchronization variables
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
int callback_executed = 0;
libp2p_stream_t *ping_stream = NULL;

typedef struct {
  char peerId[256];
  const char **addrs;
  size_t addrCount;
} PeerInfo;

static void waitForCallback(void);
static void free_peerinfo(PeerInfo *pi);
static void event_handler(int callerRet, const char *msg, size_t len,
                          void *userData);
static void topic_handler(const char *topic, uint8_t *data, size_t len,
                          void *userData);
static void peers_handler(int callerRet, const char **peerIds,
                          size_t peerIdsLen, const char *msg, size_t len,
                          void *userData);
static void signal_callback_executed(void);
static void get_value_handler(int callerRet, const uint8_t *value,
                              size_t valueLen, const char *msg, size_t len,
                              void *userData);
static void get_providers_handler(int callerRet,
                                  const Libp2pPeerInfo *providers,
                                  size_t providersLen, const char *msg,
                                  size_t len, void *userData);
static int permissive_kad_validator(const uint8_t *key, size_t keyLen,
                                    libp2p_kad_entry_record_t record,
                                    void *userData);
static int permissive_kad_selector(const uint8_t *key, size_t keyLen,
                                   const libp2p_kad_entry_record_t *records,
                                   size_t recordsLen, void *userData);
static void peerinfo_handler(int callerret, const Libp2pPeerInfo *info,
                             const char *msg, size_t len, void *userdata);

static void private_key_handler(int callerRet, const uint8_t *keyData,
                              size_t keyDataLen, const char *msg, size_t len,
                              void *userData);

static void connection_handler(int callerRet, libp2p_stream_t *conn,
                               const char *msg, size_t len, void *userData);
static void create_cid_handler(int callerRet, const char *msg, size_t len,
                               void *userData);
static void read_handler(int callerRet, const uint8_t *data, size_t dataLen,
                         const char *msg, size_t len, void *userData);
static void print_bytes(const char *label, const uint8_t *data, size_t dataLen);

// libp2p Context
libp2p_ctx_t *ctx1;
libp2p_ctx_t *ctx2;

int main(int argc, char **argv) {
  int status = 1;
  PeerInfo pInfo1 = {0};
  PeerInfo pInfo2 = {0};
  char cid_buf[CID_BUF_SIZE] = {0};

  libp2p_config_t cfg1 = libp2p_new_default_config();
  cfg1.mount_gossipsub = 1;
  cfg1.gossipsub_trigger_self = 1;
  cfg1.mount_kad_discovery = 1;
  cfg1.kad_validator = permissive_kad_validator;
  cfg1.kad_selector = permissive_kad_selector;
  cfg1.kad_user_data = NULL;

  const char *peer1_addrs[] = {
      "/ip4/127.0.0.1/tcp/5001"
  };
  cfg1.addrs = peer1_addrs;
  cfg1.addrsLen = 1;

  libp2p_private_key_t priv_key = {0};
  libp2p_new_private_key(LIBP2P_PK_RSA, private_key_handler, &priv_key);
  waitForCallback();
  cfg1.priv_key = priv_key;

  ctx1 = libp2p_new(&cfg1, event_handler, NULL);
  waitForCallback();

  libp2p_start(ctx1, event_handler, NULL);
  waitForCallback();

  // Obtaining the node's peerId and multiaddresses in which it is listening
  libp2p_peerinfo(ctx1, peerinfo_handler, &pInfo1);
  waitForCallback();

  libp2p_config_t cfg2 = libp2p_new_default_config();
  cfg2.mount_gossipsub = 1;
  cfg2.gossipsub_trigger_self = 1;
  cfg2.mount_kad_discovery = 1;
  cfg2.kad_validator = permissive_kad_validator;
  cfg2.kad_selector = permissive_kad_selector;
  cfg2.kad_user_data = NULL;
  libp2p_bootstrap_node_t bootstrap_nodes[1] = {
      {.peerId = pInfo1.peerId,
       .multiaddrs = pInfo1.addrs,
       .multiaddrsLen = pInfo1.addrCount},
  };
  cfg2.kad_bootstrap_nodes = bootstrap_nodes;
  cfg2.kad_bootstrap_nodes_len = 1;

  ctx2 = libp2p_new(&cfg2, event_handler, NULL);
  waitForCallback();

  libp2p_start(ctx2, event_handler, NULL);
  waitForCallback();

  // Obtaining the node's peerId and multiaddresses in which it is listening
  libp2p_peerinfo(ctx2, peerinfo_handler, &pInfo2);
  waitForCallback();

  libp2p_connect(ctx1, pInfo2.peerId, pInfo2.addrs, pInfo2.addrCount, 0,
                 event_handler, NULL);
  waitForCallback();

  printf("Retrieve list of peers we opened a connection to:\n");
  libp2p_connected_peers(ctx1, Direction_Out, peers_handler, NULL);
  waitForCallback();

  printf("Retrieve list of peers we received a connection from:\n");
  libp2p_connected_peers(ctx1, Direction_In, peers_handler, NULL);
  waitForCallback();

  libp2p_dial(ctx1, pInfo2.peerId, "/ipfs/ping/1.0.0", connection_handler,
              NULL);
  waitForCallback();

  uint8_t ping_payload[32] = {0};
  for (size_t i = 0; i < sizeof(ping_payload); i++) {
    ping_payload[i] = (uint8_t)i;
  }

  // Interacting with a stream

  print_bytes("Writing bytes", ping_payload, sizeof(ping_payload));
  libp2p_stream_write(ctx1, ping_stream, ping_payload, sizeof(ping_payload),
                      event_handler, NULL);
  waitForCallback();

  libp2p_stream_readExactly(ctx1, ping_stream, sizeof(ping_payload),
                            read_handler, NULL);
  waitForCallback();

  libp2p_stream_closeWithEOF(ctx1, ping_stream, event_handler, NULL);
  waitForCallback();

  libp2p_stream_release(ctx1, ping_stream, event_handler, NULL);
  waitForCallback();
  ping_stream = NULL;

  // GossipSub

  libp2p_gossipsub_subscribe(ctx1, "test", topic_handler, event_handler, NULL);
  waitForCallback();

  libp2p_gossipsub_subscribe(ctx2, "test", topic_handler, event_handler, NULL);
  waitForCallback();

  sleep(2);

  const char *msg = "Hello World";
  libp2p_gossipsub_publish(ctx1, "test", (uint8_t *)msg, strlen(msg),
                           event_handler, NULL);
  waitForCallback();

  // Kademlia operations
  printf("Found nodes:\n");
  libp2p_kad_find_node(ctx1, pInfo2.peerId, peers_handler, NULL);
  waitForCallback();

  const uint8_t keyBytes[] = {0xde, 0xad, 0xbe, 0xef};
  const uint8_t valBytes[] = "nim-libp2p";
  libp2p_kad_put_value(ctx1, keyBytes, sizeof(keyBytes), valBytes,
                       sizeof(valBytes) - 1, event_handler, NULL);
  waitForCallback();

  libp2p_kad_get_value(ctx2, keyBytes, sizeof(keyBytes), 1, get_value_handler,
                       NULL);
  waitForCallback();

  uint8_t cidData[32];
  for (size_t i = 0; i < sizeof(cidData); i++) {
    cidData[i] = (uint8_t)i;
  }
  libp2p_create_cid(1, "dag-pb", "sha2-256", cidData, sizeof(cidData),
                    create_cid_handler, cid_buf);
  waitForCallback();

  const char *cid = cid_buf;
  libp2p_kad_start_providing(ctx1, cid, event_handler, NULL);
  waitForCallback();

  libp2p_kad_add_provider(ctx1, cid, event_handler, NULL);
  waitForCallback();

  libp2p_kad_get_providers(ctx2, cid, get_providers_handler, NULL);
  waitForCallback();

  sleep(5);
  status = 0;

cleanup:
  free_peerinfo(&pInfo1);
  free_peerinfo(&pInfo2);
  free(priv_key.data);

  libp2p_stop(ctx1, event_handler, NULL);
  waitForCallback();

  libp2p_stop(ctx2, event_handler, NULL);
  waitForCallback();

  libp2p_destroy(ctx1, event_handler, NULL);
  waitForCallback();

  libp2p_destroy(ctx2, event_handler, NULL);
  waitForCallback();

  return status;
}

static void event_handler(int callerRet, const char *msg, size_t len,
                          void *userData) {
  if (callerRet == RET_OK) {
    if (msg != NULL && len != 0)
      printf("Receiving event: %s\n", msg);
  } else {
    printf("Error(%d): %s\n", callerRet, msg);
    exit(1);
  }

  signal_callback_executed();
}

static int permissive_kad_validator(const uint8_t *key, size_t keyLen,
                                    libp2p_kad_entry_record_t record,
                                    void *userData) {
  (void)key;
  (void)keyLen;
  (void)record;
  (void)userData;
  return 1; // everything is considered valid.
}

static int permissive_kad_selector(const uint8_t *key, size_t keyLen,
                                   const libp2p_kad_entry_record_t *records,
                                   size_t recordsLen, void *userData) {
  // Always pick the first candidate whenever possible. No ordering between
  // records is assumed or required.
  (void)key;
  (void)keyLen;
  (void)records;
  (void)userData;
  if (recordsLen == 0) {
    return -1;
  }
  return 0;
}

static void topic_handler(const char *topic, uint8_t *data, size_t len,
                          void *userData) {
  const char *resolved_topic = topic != NULL ? topic : "(null topic)";
  const char *payload = (const char *)data;
  printf("Topic '%s' received (%zu bytes): %.*s\n", resolved_topic, len,
         (int)len, payload != NULL ? payload : "");
}

static void peers_handler(int callerRet, const char **peerIds,
                          size_t peerIdsLen, const char *msg, size_t len,
                          void *userData) {
  if (callerRet != RET_OK) {
    printf("Error(%d): %.*s\n", callerRet, (int)len, msg != NULL ? msg : "");
    exit(1);
  }

  if (peerIds == NULL && peerIdsLen > 0) {
    printf("  (null peerIds array with non-zero length)\n");
    exit(1);
  }

  printf("Peers (%zu):\n", peerIdsLen);
  for (size_t i = 0; i < peerIdsLen; i++) {
    printf("  %s\n", peerIds[i]);
  }

  signal_callback_executed();
}

static void peerinfo_handler(int callerRet, const Libp2pPeerInfo *info,
                             const char *msg, size_t len, void *userData) {
  PeerInfo *pi = (PeerInfo *)userData;

  if (callerRet != RET_OK || info == NULL) {
    if (msg != NULL && len > 0) {
      printf("Error(%d): %.*s\n", callerRet, (int)len, msg);
    } else {
      printf("Error(%d): peerinfo callback failed\n", callerRet);
    }
    exit(1);
  }

  free_peerinfo(pi);

  if (info->peerId != NULL) {
    strncpy(pi->peerId, info->peerId, sizeof(pi->peerId) - 1);
    pi->peerId[sizeof(pi->peerId) - 1] = '\0';
  }

  pi->addrCount = info->addrsLen;
  if (info->addrsLen > 0 && info->addrs != NULL) {
    pi->addrs = (const char **)calloc(info->addrsLen, sizeof(char *));
    if (pi->addrs == NULL) {
      printf("Error: out of memory copying peerinfo addrs\n");
      exit(1);
    }
    for (size_t i = 0; i < info->addrsLen; i++) {
      const char *addr = info->addrs[i];
      if (addr != NULL) {
        size_t len = strlen(addr);
        char *buf = (char *)malloc(len + 1);
        if (buf == NULL) {
          printf("Error: out of memory copying peerinfo addr\n");
          exit(1);
        }
        memcpy(buf, addr, len + 1);
        pi->addrs[i] = buf;
      }
    }
  }

  signal_callback_executed();
}

static void create_cid_handler(int callerRet, const char *msg, size_t len,
                               void *userData) {
  char *buf = (char *)userData;
  if (callerRet != RET_OK) {
    printf("Create CID error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }

  if (msg == NULL || len == 0) {
    printf("Create CID returned no data\n");
    exit(1);
  }

  if (buf == NULL) {
    printf("Create CID handler missing buffer\n");
    exit(1);
  }

  size_t copyLen = len;
  if (copyLen >= CID_BUF_SIZE)
    copyLen = CID_BUF_SIZE - 1;
  memcpy(buf, msg, copyLen);
  buf[copyLen] = '\0';
  printf("Generated CID: %s\n", buf);

  signal_callback_executed();
}

static void get_value_handler(int callerRet, const uint8_t *data,
                              size_t dataLen, const char *msg, size_t len,
                              void *userData) {
  if (callerRet != RET_OK) {
    printf("GetValue error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");

    exit(1);
  }

  printf("GetValue received (%zu bytes): ", dataLen);
  for (size_t i = 0; i < dataLen; i++) {
    printf("%02x", data[i]);
  }
  printf("\n");

  signal_callback_executed();
}

static void private_key_handler(
    int callerRet,
    const uint8_t *keyData,
    size_t keyDataLen,
    const char *msg,
    size_t len,
    void *userData
) {
  if (callerRet != RET_OK || keyDataLen == 0 || keyData == NULL) {
    printf("Private key error(%d): %.*s\n", callerRet, (int)len, msg ? msg : "");
    exit(1);
  }

  libp2p_private_key_t *priv_key =
      (libp2p_private_key_t *)userData;

  uint8_t *buf = (uint8_t *)malloc(keyDataLen);
  if (!buf) {
    fprintf(stderr, "Out of memory while copying private key\n");
    exit(1);
  }

  memcpy(buf, keyData, keyDataLen);

  priv_key->data = buf;

  signal_callback_executed();
}

static void get_providers_handler(int callerRet,
                                  const Libp2pPeerInfo *providers,
                                  size_t providersLen, const char *msg,
                                  size_t len, void *userData) {
  if (callerRet != RET_OK) {
    printf("GetProviders error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }

  printf("Providers (%zu):\n", providersLen);
  for (size_t i = 0; i < providersLen; i++) {
    const Libp2pPeerInfo *p = &providers[i];
    printf("  %s\n", p->peerId != NULL ? p->peerId : "(null peerId)");
    for (size_t j = 0; j < p->addrsLen; j++) {
      printf("    %s\n", p->addrs[j] != NULL ? p->addrs[j] : "(null addr)");
    }
  }

  signal_callback_executed();
}

static void connection_handler(int callerRet, libp2p_stream_t *conn,
                               const char *msg, size_t len, void *userData) {
  if (callerRet != RET_OK) {
    printf("Error(%d): %.*s\n", callerRet, (int)len, msg != NULL ? msg : "");
    exit(1);
  }

  ping_stream = conn;

  signal_callback_executed();
}

static void signal_callback_executed(void) {
  pthread_mutex_lock(&mutex);
  callback_executed = 1;
  pthread_cond_signal(&cond);
  pthread_mutex_unlock(&mutex);
}

static void waitForCallback(void) {
  pthread_mutex_lock(&mutex);
  while (!callback_executed) {
    pthread_cond_wait(&cond, &mutex);
  }
  callback_executed = 0;
  pthread_mutex_unlock(&mutex);
}

static void read_handler(int callerRet, const uint8_t *data, size_t dataLen,
                         const char *msg, size_t len, void *userData) {
  if (callerRet != RET_OK) {
    printf("Read error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }

  printf("Read %zu bytes from ping stream\n", dataLen);
  print_bytes("Read bytes", data, dataLen);

  pthread_mutex_lock(&mutex);
  callback_executed = 1;
  pthread_cond_signal(&cond);
  pthread_mutex_unlock(&mutex);
}

static void free_peerinfo(PeerInfo *pi) {
  if (pi == NULL)
    return;

  for (size_t i = 0; i < pi->addrCount; i++)
    free((void *)pi->addrs[i]);
  free(pi->addrs);
  pi->addrs = NULL;
  pi->addrCount = 0;
  pi->peerId[0] = '\0';
}

static void print_bytes(const char *label, const uint8_t *data,
                        size_t dataLen) {
  printf("%s (%zu bytes):", label, dataLen);
  for (size_t i = 0; i < dataLen; i++) {
    if (i % 16 == 0)
      printf("\n  ");
    printf("%02x ", data[i]);
  }
  printf("\n");
}
