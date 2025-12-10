#include "../../cbind/libp2p.h"
#include "jsmn.h"
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
static int jsoneq(const char *json, jsmntok_t *tok, const char *s);
static void free_peerinfo(PeerInfo *pi);
static int parse_peerinfo(const char *json, PeerInfo *out);
static void event_handler(int callerRet, const char *msg, size_t len,
                          void *userData);
static void peerinfo_handler(int callerRet, const char *msg, size_t len,
                             void *userData);

// libp2p Context
void *ctx1;
void *ctx2;

int main(int argc, char **argv) {
  int status = 1;
  char *peerinfo = NULL;
  PeerInfo pi = {0};

  ctx1 = libp2p_new(event_handler, NULL);
  waitForCallback();

  libp2p_start(ctx1, event_handler, NULL);
  waitForCallback();

  ctx2 = libp2p_new(event_handler, NULL);
  waitForCallback();

  libp2p_start(ctx2, event_handler, NULL);
  waitForCallback();

  libp2p_peerinfo(ctx2, peerinfo_handler, &peerinfo);
  waitForCallback();

  if (parse_peerinfo(peerinfo, &pi) != 0) {
    printf("Missing peerId or addresses in peerinfo\n");
    goto cleanup;
  }

  libp2p_connect(ctx1, pi.peerId, pi.addrs, pi.addrCount, 0, event_handler,
                 NULL);

  sleep(5);
  status = 0;

cleanup:
  free(peerinfo);
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

static void peerinfo_handler(int callerRet, const char *msg, size_t len,
                             void *userData) {
  char **result = (char **)userData;

  if (callerRet != RET_OK) {
    printf("Error(%d): %s\n", callerRet, msg);
    exit(1);
  }

  if (result != NULL) {
    free(*result);
    *result = (char *)malloc(len + 1);
    if (*result != NULL) {
      memcpy(*result, msg, len);
      (*result)[len] = '\0';
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

static int jsoneq(const char *json, jsmntok_t *tok, const char *s) {
  if (tok->type == JSMN_STRING && (int)strlen(s) == tok->end - tok->start &&
      strncmp(json + tok->start, s, tok->end - tok->start) == 0) {
    return 0;
  }
  return -1;
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

static int parse_peerinfo(const char *json, PeerInfo *out) {
  jsmn_parser parser;
  jsmntok_t tokens[64];
  jsmn_init(&parser);

  out->addrCount = 0;
  out->addrs = NULL;
  out->peerId[0] = '\0';

  int r = jsmn_parse(&parser, json, strlen(json), tokens, 64);
  if (r < 0 || tokens[0].type != JSMN_OBJECT) {
    return -1;
  }

  int addrsSize = 0;
  for (int i = 1; i < r; i++) {
    if (jsoneq(json, &tokens[i], "addrs") == 0 && i + 1 < r) {
      addrsSize = tokens[i + 1].size;
      break;
    }
  }
  if (addrsSize > 0) {
    out->addrs = (const char **)calloc(addrsSize, sizeof(char *));
    if (out->addrs == NULL) {
      return -1;
    }
  }

  for (int i = 1; i < r; i++) {
    if (jsoneq(json, &tokens[i], "peerId") == 0 && i + 1 < r) {
      size_t len = tokens[i + 1].end - tokens[i + 1].start;
      if (len >= sizeof(out->peerId))
        len = sizeof(out->peerId) - 1;
      memcpy(out->peerId, json + tokens[i + 1].start, len);
      out->peerId[len] = '\0';
      i++;
    } else if (jsoneq(json, &tokens[i], "addrs") == 0 && i + 1 < r) {
      int arraySize = tokens[i + 1].size;
      int j = i + 2;
      for (int k = 0; k < arraySize && j < r; k++, j++) {
        size_t len = tokens[j].end - tokens[j].start;
        char *buf = (char *)malloc(len + 1);
        if (buf != NULL) {
          memcpy(buf, json + tokens[j].start, len);
          buf[len] = '\0';
          out->addrs[out->addrCount] = buf;
          out->addrCount++;
        }
      }
      i = j - 1;
    }
  }

  if (out->peerId[0] != '\0' && out->addrCount > 0) {
    return 0;
  }

  free_peerinfo(out);
  return -1;
}
