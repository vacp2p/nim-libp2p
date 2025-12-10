#include "libp2p.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

// Shared synchronization variables
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
int callback_executed = 0;

void waitForCallback() {
  pthread_mutex_lock(&mutex);
  while (!callback_executed) {
    pthread_cond_wait(&cond, &mutex);
  }
  callback_executed = 0;
  pthread_mutex_unlock(&mutex);
}

#define LIBP2P_CALL(call)                                                      \
  do {                                                                         \
    int ret = call;                                                            \
    if (ret != 0) {                                                            \
      printf("Failed the call to: %s. Returned code: %d\n", #call, ret);       \
      exit(callerRet);                                                         \
    }                                                                          \
    waitForCallback();                                                         \
  } while (0)

void signal_cond() {
  pthread_mutex_lock(&mutex);
  callback_executed = 1;
  pthread_cond_signal(&cond);
  pthread_mutex_unlock(&mutex);
}

void event_handler(int callerRet, const char *msg, size_t len, void *userData) {
  if (callerRet == RET_OK) {
    printf("Receiving event: %s\n", msg);
  } else {
    printf("Error(%d): %s\n", callerRet, msg);
    exit(1);
  }
  signal_cond();
}

// libp2p Context
void *ctx;

int main(int argc, char **argv) {

  ctx = libp2p_new(event_handler, NULL);
  waitForCallback();

  libp2p_start(ctx, event_handler, NULL);
  waitForCallback();

  // TODO: start another node and dial that node address once
  // libp2p_peerinfo(ctx) is implemented

  const char *multiaddrs[] = {
      "/dns4/boot-01.do-ams3.status.staging.status.im/tcp/30303"};

  libp2p_connect(ctx, "16Uiu2HAmQE7FXQc6iZHdBzYfw3qCSDa9dLc1wsBJKoP4aZvztq2d",
                 multiaddrs, 1, 0, event_handler, NULL);

  libp2p_stop(ctx, event_handler, NULL);
  waitForCallback();

  libp2p_destroy(ctx, event_handler, NULL);
  waitForCallback();

  return 0;
}