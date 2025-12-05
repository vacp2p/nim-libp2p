#include "../../cbind/libp2p.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Shared synchronization variables
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
int callback_executed = 0;

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

// libp2p Context
void *ctx1;
void *ctx2;

int main(int argc, char **argv) {
  int status = 1;
  PeerInfo pi = {0};

  ctx1 = libp2p_new(event_handler, NULL);
  waitForCallback();

  libp2p_start(ctx1, event_handler, NULL);
  waitForCallback();

  ctx2 = libp2p_new(event_handler, NULL);
  waitForCallback();

  libp2p_start(ctx2, event_handler, NULL);
  waitForCallback();

  libp2p_peerinfo(ctx2, peerinfo_handler, &pi);
  waitForCallback();

  libp2p_connect(ctx1, pi.peerId, pi.addrs, pi.addrCount, 0, event_handler,
                 NULL);
  waitForCallback();

  sleep(5);
  status = 0;

cleanup:
  free_peerinfo(&pi);

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
    if (msg != NULL)
      printf("Receiving event: %s\n", msg);
  } else {
    printf("Error(%d): %s\n", callerRet, msg);
    exit(1);
  }

  pthread_mutex_lock(&mutex);
  callback_executed = 1;
  pthread_cond_signal(&cond);
  pthread_mutex_unlock(&mutex);
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
