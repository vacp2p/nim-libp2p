#pragma once
// Shared helpers for the C binding examples. The generated API is asynchronous:
// every call takes a result callback and returns immediately, and the callback
// fires from the library's dispatch thread. These helpers turn a call back into
// a blocking step by polling a `done` flag the callback sets.
#include "libp2p.h"

#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#if defined(__STDC_NO_ATOMICS__)
#  error "C11 atomics required"
#endif

#if defined(_WIN32)
#  include <windows.h>
static inline void sleep_ms(unsigned ms) {
  Sleep(ms);
}
#else
#  include <time.h>
static inline void sleep_ms(unsigned ms) {
  struct timespec t = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000L * 1000L};
  nanosleep(&t, NULL);
}
#endif

// Poll up to ~10s for a callback to fire; false means it never did, so the
// caller can report a stuck call instead of treating it as an empty success.
static inline bool wait_done(atomic_int* done) {
  for (int i = 0; i < 1000 && !atomic_load(done); i++)
    sleep_ms(10);
  return atomic_load(done) != 0;
}

// start/stop/connect/mount/subscribe/write/release/close all reply with just a
// bool, so one waiter and callback cover them.
typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
} BoolWaiter;

static inline void on_bool(int ec, const bool* reply, const char* em, void* ud) {
  (void)reply;
  BoolWaiter* w = (BoolWaiter*)ud;
  w->err_code = ec;
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

static inline bool await_bool(BoolWaiter* w, const char* label) {
  if (!wait_done(&w->done)) {
    fprintf(stderr, "%s: call did not complete\n", label);
    return false;
  }
  if (w->err_code != 0) {
    fprintf(stderr, "%s: %s\n", label, w->err[0] ? w->err : "unknown");
    return false;
  }
  return true;
}

// Issue a bool-returning call, block for its callback and report failure. The
// comma operator sequences reset → submit → wait, so `call` must pass `on_bool`
// and `&w` (e.g. AWAIT_BOOL(w, libp2p_ctx_start(ctx, on_bool, &w), "start")).
#define AWAIT_BOOL(w, call, label) \
  (memset(&(w), 0, sizeof(w)), (call), await_bool(&(w), (label)))

typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  LibP2PCtx* ctx;
} CreateWaiter;

static inline void on_created(int ec, LibP2PCtx* ctx, const char* em, void* ud) {
  CreateWaiter* w = (CreateWaiter*)ud;
  w->err_code = ec;
  w->ctx = ctx;
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

// The context handed to the constructor callback is owned by the caller, who
// releases it with libp2p_ctx_destroy; NULL on failure (message already logged).
static inline LibP2PCtx* await_create(const Libp2pConfig* cfg, const char* label) {
  CreateWaiter w;
  memset(&w, 0, sizeof(w));
  libp2p_ctx_create(cfg, on_created, &w);
  if (!wait_done(&w.done) || w.err_code != 0 || !w.ctx) {
    fprintf(stderr, "create %s: %s\n", label, w.err[0] ? w.err : "unknown");
    return NULL;
  }
  return w.ctx;
}

// Response strings are owned by the binding and valid only during the callback,
// so peerinfo is copied into caller-owned buffers here.
typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  char peerId[128];
  char addrs[16][256];
  size_t naddrs;
} PeerInfoWaiter;

static inline void on_peerinfo(
    int ec, const PeerInfoResponse* reply, const char* em, void* ud) {
  PeerInfoWaiter* w = (PeerInfoWaiter*)ud;
  w->err_code = ec;
  if (reply) {
    if (reply->peerId.data)
      snprintf(w->peerId, sizeof(w->peerId), "%s", reply->peerId.data);
    w->naddrs = reply->addrs.len < 16 ? reply->addrs.len : 16;
    for (size_t i = 0; i < w->naddrs; i++)
      if (reply->addrs.data[i].data)
        snprintf(w->addrs[i], sizeof(w->addrs[i]), "%s", reply->addrs.data[i].data);
  }
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

static inline bool await_peerinfo(LibP2PCtx* ctx, PeerInfoWaiter* w, const char* label) {
  memset(w, 0, sizeof(*w));
  libp2p_ctx_peer_info(ctx, on_peerinfo, w);
  if (!wait_done(&w->done) || w->err_code != 0) {
    fprintf(stderr, "%s: %s\n", label, w->err[0] ? w->err : "unknown");
    return false;
  }
  return true;
}
