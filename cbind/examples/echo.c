#include "../../cbind/libp2p.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ECHO_PROTO "/cbind/echo/1.0.0"
#define ECHO_MAX_SIZE 4096

typedef struct {
  char peerId[256];
  const char **addrs;
  size_t addrCount;
} PeerInfo;

typedef struct {
  libp2p_ctx_t *ctx;
  libp2p_stream_t *stream;
} EchoState;

// The sample waits synchronously in main, but libp2p operations complete
// through callbacks. Server-side protocol callbacks do not use this condition
// variable: they must keep their own state and continue asynchronously.
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int callback_executed = 0;

static libp2p_stream_t *client_stream = NULL;
static const char *expected_echo = "hello from cbind echo";
static int echo_matched = 0;

static void waitForCallback(void);
static void signal_callback_executed(void);
static void free_peerinfo(PeerInfo *pi);
static void event_handler(int callerRet, const char *msg, size_t len,
                          void *userData);
static void peerinfo_handler(int callerRet, const Libp2pPeerInfo *info,
                             const char *msg, size_t len, void *userData);
static void connection_handler(int callerRet, libp2p_stream_t *conn,
                               const char *msg, size_t len, void *userData);
static void client_read_handler(int callerRet, const uint8_t *data,
                                size_t dataLen, const char *msg, size_t len,
                                void *userData);
static void echo_protocol_handler(libp2p_ctx_t *ctx, libp2p_stream_t *stream,
                                  const char *proto, size_t protoLen,
                                  void *userData);
static void echo_read_handler(int callerRet, const uint8_t *data,
                              size_t dataLen, const char *msg, size_t len,
                              void *userData);
static void echo_write_handler(int callerRet, const char *msg, size_t len,
                               void *userData);
static void echo_close_handler(int callerRet, const char *msg, size_t len,
                               void *userData);
static void echo_release_handler(int callerRet, const char *msg, size_t len,
                                 void *userData);

int main(void) {
  int status = 1;
  libp2p_ctx_t *server = NULL;
  libp2p_ctx_t *client = NULL;
  PeerInfo serverInfo = {0};

  const char *server_addrs[] = {"/ip4/127.0.0.1/tcp/5013"};

  libp2p_config_t serverCfg = libp2p_new_default_config();
  serverCfg.mount_gossipsub = 0;
  serverCfg.mount_kad = 0;
  serverCfg.mount_service_discovery = 0;
  serverCfg.addrs = server_addrs;
  serverCfg.addrsLen = 1;
  serverCfg.muxer = LIBP2P_MUXER_MPLEX;
  serverCfg.transport = LIBP2P_TRANSPORT_TCP;

  server = libp2p_new(&serverCfg, event_handler, NULL);
  waitForCallback();

  // Mount before start so peers learn about the protocol during identify.
  // Mounting after start is supported too, but existing peers may need another
  // identify exchange before they discover the new protocol.
  libp2p_mount_protocol(server, ECHO_PROTO, echo_protocol_handler,
                        event_handler, NULL);
  waitForCallback();

  libp2p_start(server, event_handler, NULL);
  waitForCallback();

  libp2p_peerinfo(server, peerinfo_handler, &serverInfo);
  waitForCallback();

  printf("Echo server started: %s\n", serverInfo.peerId);
  for (size_t i = 0; i < serverInfo.addrCount; i++) {
    printf("  %s\n", serverInfo.addrs[i]);
  }

  libp2p_config_t clientCfg = libp2p_new_default_config();
  clientCfg.mount_gossipsub = 0;
  clientCfg.mount_kad = 0;
  clientCfg.mount_service_discovery = 0;
  clientCfg.muxer = LIBP2P_MUXER_MPLEX;
  clientCfg.transport = LIBP2P_TRANSPORT_TCP;

  client = libp2p_new(&clientCfg, event_handler, NULL);
  waitForCallback();

  libp2p_start(client, event_handler, NULL);
  waitForCallback();

  // Establish a peer connection first, then open a protocol stream with dial.
  libp2p_connect(client, serverInfo.peerId, serverInfo.addrs,
                 serverInfo.addrCount, 0, event_handler, NULL);
  waitForCallback();

  libp2p_dial(client, serverInfo.peerId, ECHO_PROTO, connection_handler, NULL);
  waitForCallback();
  if (client_stream == NULL) {
    printf("Error: dial did not return a stream\n");
    goto cleanup;
  }

  printf("Client sending: %s\n", expected_echo);
  libp2p_stream_writeLp(client, client_stream, (const uint8_t *)expected_echo,
                        strlen(expected_echo), event_handler, NULL);
  waitForCallback();

  libp2p_stream_readLp(client, client_stream, ECHO_MAX_SIZE,
                       client_read_handler, NULL);
  waitForCallback();

  if (!echo_matched) {
    printf("Error: echoed payload did not match\n");
    goto cleanup;
  }

  libp2p_stream_closeWithEOF(client, client_stream, event_handler, NULL);
  waitForCallback();

  libp2p_stream_release(client, client_stream, event_handler, NULL);
  waitForCallback();
  client_stream = NULL;

  status = 0;

cleanup:
  free_peerinfo(&serverInfo);

  if (client_stream != NULL && client != NULL) {
    libp2p_stream_release(client, client_stream, event_handler, NULL);
    waitForCallback();
    client_stream = NULL;
  }

  if (client != NULL) {
    libp2p_stop(client, event_handler, NULL);
    waitForCallback();
    libp2p_destroy(client, event_handler, NULL);
    waitForCallback();
  }

  if (server != NULL) {
    libp2p_stop(server, event_handler, NULL);
    waitForCallback();
    libp2p_destroy(server, event_handler, NULL);
    waitForCallback();
  }

  return status;
}

static void event_handler(int callerRet, const char *msg, size_t len,
                          void *userData) {
  (void)userData;
  if (callerRet != RET_OK) {
    printf("Error(%d): %.*s\n", callerRet, (int)len, msg != NULL ? msg : "");
    exit(1);
  }

  signal_callback_executed();
}

static void peerinfo_handler(int callerRet, const Libp2pPeerInfo *info,
                             const char *msg, size_t len, void *userData) {
  PeerInfo *pi = (PeerInfo *)userData;

  if (callerRet != RET_OK || info == NULL) {
    printf("PeerInfo error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }

  free_peerinfo(pi);

  if (info->peerId != NULL) {
    strncpy(pi->peerId, info->peerId, sizeof(pi->peerId) - 1);
    pi->peerId[sizeof(pi->peerId) - 1] = '\0';
  }

  // PeerInfo fields are owned by the callback and become invalid on return.
  // Copy the listen addresses because the client uses them after this callback.
  pi->addrCount = info->addrsLen;
  if (info->addrsLen > 0 && info->addrs != NULL) {
    pi->addrs = (const char **)calloc(info->addrsLen, sizeof(char *));
    if (pi->addrs == NULL) {
      printf("Error: out of memory copying peerinfo addrs\n");
      exit(1);
    }

    for (size_t i = 0; i < info->addrsLen; i++) {
      const char *addr = info->addrs[i];
      if (addr == NULL)
        continue;

      size_t addrLen = strlen(addr);
      char *copy = (char *)malloc(addrLen + 1);
      if (copy == NULL) {
        printf("Error: out of memory copying peerinfo addr\n");
        exit(1);
      }
      memcpy(copy, addr, addrLen + 1);
      pi->addrs[i] = copy;
    }
  }

  signal_callback_executed();
}

static void connection_handler(int callerRet, libp2p_stream_t *conn,
                               const char *msg, size_t len, void *userData) {
  (void)userData;
  if (callerRet != RET_OK) {
    printf("Dial error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }

  client_stream = conn;
  signal_callback_executed();
}

static void client_read_handler(int callerRet, const uint8_t *data,
                                size_t dataLen, const char *msg, size_t len,
                                void *userData) {
  (void)userData;
  if (callerRet != RET_OK) {
    printf("Client read error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    exit(1);
  }

  printf("Client received: %.*s\n", (int)dataLen,
         data != NULL ? (char *)data : "");
  echo_matched = data != NULL && dataLen == strlen(expected_echo) &&
                 memcmp(data, expected_echo, dataLen) == 0;
  signal_callback_executed();
}

static void echo_protocol_handler(libp2p_ctx_t *ctx, libp2p_stream_t *stream,
                                  const char *proto, size_t protoLen,
                                  void *userData) {
  (void)userData;
  EchoState *state = (EchoState *)calloc(1, sizeof(EchoState));
  if (state == NULL) {
    printf("Echo server: out of memory\n");
    libp2p_stream_release(ctx, stream, echo_release_handler, NULL);
    return;
  }

  state->ctx = ctx;
  state->stream = stream;

  printf("Echo server accepted protocol: %.*s\n", (int)protoLen,
         proto != NULL ? proto : "");
  // The protocol handler must not block on this read. libp2p keeps this
  // incoming stream alive until echo_release_handler calls
  // libp2p_stream_release.
  libp2p_stream_readLp(ctx, stream, ECHO_MAX_SIZE, echo_read_handler, state);
}

static void echo_read_handler(int callerRet, const uint8_t *data,
                              size_t dataLen, const char *msg, size_t len,
                              void *userData) {
  EchoState *state = (EchoState *)userData;
  if (state == NULL)
    return;

  if (callerRet != RET_OK) {
    printf("Echo server read error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    libp2p_stream_release(state->ctx, state->stream, echo_release_handler,
                          state);
    return;
  }

  printf("Echo server echoing %zu bytes\n", dataLen);
  // The read buffer is valid only for this callback, but writeLp copies it
  // before returning, so it is safe to pass through directly here.
  libp2p_stream_writeLp(state->ctx, state->stream, data, dataLen,
                        echo_write_handler, state);
}

static void echo_write_handler(int callerRet, const char *msg, size_t len,
                               void *userData) {
  EchoState *state = (EchoState *)userData;
  if (state == NULL)
    return;

  if (callerRet != RET_OK) {
    printf("Echo server write error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
    libp2p_stream_release(state->ctx, state->stream, echo_release_handler,
                          state);
    return;
  }

  // closeWithEOF tells the client no more frames are coming; release below
  // returns ownership of the incoming stream handle to the binding.
  libp2p_stream_closeWithEOF(state->ctx, state->stream, echo_close_handler,
                             state);
}

static void echo_close_handler(int callerRet, const char *msg, size_t len,
                               void *userData) {
  EchoState *state = (EchoState *)userData;
  if (state == NULL)
    return;

  if (callerRet != RET_OK) {
    printf("Echo server close error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
  }

  libp2p_stream_release(state->ctx, state->stream, echo_release_handler, state);
}

static void echo_release_handler(int callerRet, const char *msg, size_t len,
                                 void *userData) {
  EchoState *state = (EchoState *)userData;
  if (callerRet != RET_OK) {
    printf("Echo server release error(%d): %.*s\n", callerRet, (int)len,
           msg != NULL ? msg : "");
  }
  free(state);
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

  for (size_t i = 0; i < pi->addrCount; i++) {
    free((void *)pi->addrs[i]);
  }
  free(pi->addrs);
  pi->addrs = NULL;
  pi->addrCount = 0;
  pi->peerId[0] = '\0';
}
