#include "../../cbind/libp2p.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define NUM_NODES 5

pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
int callback_executed = 0;
static libp2p_stream_t *mix_conn = NULL;

typedef struct {
  char peerId[256];
  const char **addrs;
  size_t addrCount;
} PeerInfo;

static void waitForCallback(void);
static void free_peerinfo(PeerInfo *pi);
static void event_handler(int callerRet, const char *msg, size_t len,
                          void *userData);
static void peerinfo_handler(int callerRet, const Libp2pPeerInfo *info,
                             const char *msg, size_t len, void *userData);
static void pubkey_handler(int callerRet, const uint8_t *data, size_t dataLen,
                           const char *msg, size_t len, void *userData);
static void private_key_handler(int callerRet, const uint8_t *keyData,
                                size_t keyDataLen, const char *msg, size_t len,
                                void *userData);
static void connection_handler(int callerRet, libp2p_stream_t *conn,
                               const char *msg, size_t len, void *userData);
static void read_handler(int callerRet, const uint8_t *data, size_t dataLen,
                         const char *msg, size_t len, void *userData);
static void signal_callback_executed(void);
static void fill_random(uint8_t *buf, size_t len);

int main(int argc, char **argv) {
  int status = 1;
  libp2p_ctx_t *nodes[NUM_NODES] = {0};
  PeerInfo infos[NUM_NODES] = {0};
  libp2p_curve25519_key_t mix_priv_keys[NUM_NODES] = {0};
  libp2p_curve25519_key_t mix_pub_keys[NUM_NODES] = {0};
  // Needed for mix node pool entries (mix pool stores mix pubkey + libp2p
  // pubkey).
  libp2p_secp256k1_pubkey_t libp2p_pub_keys[NUM_NODES] = {0};
  libp2p_private_key_t libp2p_priv_keys[NUM_NODES] = {0};

  for (int i = 0; i < NUM_NODES; i++) {
    libp2p_config_t cfg = libp2p_new_default_config();
    cfg.mount_mix = 1;
    cfg.mount_gossipsub = 0;

    libp2p_new_private_key(LIBP2P_PK_SECP256K1, private_key_handler,
                           &libp2p_priv_keys[i]);
    waitForCallback();
    cfg.priv_key = libp2p_priv_keys[i];

    nodes[i] = libp2p_new(&cfg, event_handler, NULL);
    waitForCallback();

    libp2p_start(nodes[i], event_handler, NULL);
    waitForCallback();

    libp2p_peerinfo(nodes[i], peerinfo_handler, &infos[i]);
    waitForCallback();

    libp2p_mix_generate_priv_key(&mix_priv_keys[i]);
    libp2p_mix_public_key(mix_priv_keys[i], &mix_pub_keys[i]);

    libp2p_public_key(nodes[i], pubkey_handler, &libp2p_pub_keys[i]);
    waitForCallback();

    if (infos[i].addrCount == 0 || infos[i].addrs == NULL ||
        infos[i].addrs[0] == NULL) {
      printf("Error: node %d has no listening address\n", i);
      goto cleanup;
    }

    // Mix node identity is separate from libp2p identity; this binds the node's
    // listening multiaddr to the mix keypair so other mix nodes can route
    // through it.
    libp2p_mix_set_node_info(nodes[i], infos[i].addrs[0], mix_priv_keys[i],
                             event_handler, NULL);
    waitForCallback();

    // Exit-layer needs to know how to read application protocol payloads.
    libp2p_mix_register_dest_read_behavior(nodes[i], "/ipfs/ping/1.0.0",
                                           LIBP2P_MIX_READ_EXACTLY, 32,
                                           event_handler, NULL);
    waitForCallback();

    printf("Node %d started: %s\n", i, infos[i].peerId);
    for (size_t j = 0; j < infos[i].addrCount; j++) {
      printf("  %s\n", infos[i].addrs[j]);
    }
  }

  printf("Started %d nodes with mix enabled.\n", NUM_NODES);

  // Each mix node needs the public info of the others to build random paths.
  printf("Populating mix node pools...\n");
  for (int i = 0; i < NUM_NODES; i++) {
    for (int j = 0; j < NUM_NODES; j++) {
      if (i == j)
        continue;
      libp2p_mix_nodepool_add(nodes[i], infos[j].peerId, infos[j].addrs[0],
                              mix_pub_keys[j], libp2p_pub_keys[j],
                              event_handler, NULL);
      waitForCallback();
    }
  }

  // Mix dial from node 1 to node 5 (1-based indexing).
  if (infos[4].addrCount == 0 || infos[4].addrs == NULL ||
      infos[4].addrs[0] == NULL) {
    printf("Error: node 5 has no listening address\n");
    goto cleanup;
  }
  libp2p_mix_dial_with_reply(nodes[0], infos[4].peerId, infos[4].addrs[0],
                             "/ipfs/ping/1.0.0", 1, 0, connection_handler,
                             NULL);
  waitForCallback();
  if (mix_conn == NULL) {
    printf("Error: mix dial did not return a connection\n");
    goto cleanup;
  }

  uint8_t payload[32];
  fill_random(payload, sizeof(payload));
  libp2p_stream_write(nodes[0], mix_conn, payload, sizeof(payload),
                      event_handler, NULL);
  waitForCallback();

  libp2p_stream_readExactly(nodes[0], mix_conn, sizeof(payload), read_handler,
                            NULL);
  waitForCallback();

  libp2p_stream_close(nodes[0], mix_conn, event_handler, NULL);
  waitForCallback();

  libp2p_stream_release(nodes[0], mix_conn, event_handler, NULL);
  waitForCallback();
  mix_conn = NULL;

  status = 0;

  sleep(5);

cleanup:
  for (int i = 0; i < NUM_NODES; i++) {
    free_peerinfo(&infos[i]);
  }

  for (int i = 0; i < NUM_NODES; i++) {
    free(libp2p_priv_keys[i].data);
    libp2p_priv_keys[i].data = NULL;
    libp2p_priv_keys[i].dataLen = 0;
  }

  for (int i = 0; i < NUM_NODES; i++) {
    if (nodes[i] != NULL) {
      libp2p_stop(nodes[i], event_handler, NULL);
      waitForCallback();
      libp2p_destroy(nodes[i], event_handler, NULL);
      waitForCallback();
      nodes[i] = NULL;
    }
  }

  return status;
}

static void event_handler(int callerRet, const char *msg, size_t len,
                          void *userData) {
  if (callerRet == RET_OK) {
    if (msg != NULL && len != 0)
      printf("Event: %s\n", msg);
  } else {
    printf("Error(%d): %s\n", callerRet, msg != NULL ? msg : "");
    exit(1);
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

static void pubkey_handler(int callerRet, const uint8_t *data, size_t dataLen,
                           const char *msg, size_t len, void *userData) {
  libp2p_secp256k1_pubkey_t *out = (libp2p_secp256k1_pubkey_t *)userData;

  if (callerRet != RET_OK) {
    printf("Error(%d): %.*s\n", callerRet, (int)len, msg != NULL ? msg : "");
    exit(1);
  }

  if (data == NULL || dataLen != sizeof(out->bytes)) {
    printf("Error: invalid public key bytes (len=%zu)\n", dataLen);
    exit(1);
  }

  memcpy(out->bytes, data, sizeof(out->bytes));

  signal_callback_executed();
}

static void private_key_handler(int callerRet, const uint8_t *keyData,
                                size_t keyDataLen, const char *msg, size_t len,
                                void *userData) {
  if (callerRet != RET_OK || keyDataLen == 0 || keyData == NULL) {
    printf("Private key error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }

  libp2p_private_key_t *priv_key = (libp2p_private_key_t *)userData;

  uint8_t *buf = (uint8_t *)malloc(keyDataLen);
  if (!buf) {
    fprintf(stderr, "Out of memory while copying private key\n");
    exit(1);
  }

  memcpy(buf, keyData, keyDataLen);
  priv_key->data = buf;
  priv_key->dataLen = keyDataLen;

  signal_callback_executed();
}

static void connection_handler(int callerRet, libp2p_stream_t *conn,
                               const char *msg, size_t len, void *userData) {
  if (callerRet != RET_OK) {
    printf("Error(%d): %.*s\n", callerRet, (int)len, msg != NULL ? msg : "");
    exit(1);
  }

  (void)conn;
  mix_conn = conn;
  (void)userData;

  signal_callback_executed();
}

static void fill_random(uint8_t *buf, size_t len) {
  for (size_t i = 0; i < len; i++) {
    buf[i] = (uint8_t)(rand() & 0xFF);
  }
}

static void read_handler(int callerRet, const uint8_t *data, size_t dataLen,
                         const char *msg, size_t len, void *userData) {
  if (callerRet != RET_OK) {
    printf("Read error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }
  printf("========================================\n");
  printf("========================================\n");
  printf("========================================\n");
  printf("Read %zu bytes\n", dataLen);
  (void)data;
  (void)userData;

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
