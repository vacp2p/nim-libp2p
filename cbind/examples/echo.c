// Echo over a custom `/cbind/echo/1.0.0` protocol: a server node echoes the
// bytes it reads; a client node dials, sends a payload and verifies the echo.
// The generated bindings are asynchronous, so every call is wrapped with the
// blocking helpers in common.h. nim-ffi rejects reentrant calls (a method may
// not be invoked from a callback running on its dispatch thread) and its worker
// threads own the Nim GC state, so all calls are made from `main`: the incoming-
// stream handler only hands `main` the stream id, which it then serves inline.
#include "common.h"

// TransportType / MuxerType ordinals, mirrored from cbind/libp2p.nim.
static const int64_t TransportTcp = 1;
static const int64_t MuxerMplex = 0;

static const char* EchoProto = "/cbind/echo/1.0.0";
static const int64_t EchoMaxSize = 4096;

// Single-slot hand-off from the incoming-stream event to main.
static atomic_int g_have_stream = 0;
static uint64_t g_stream_id = 0;

static void onIncomingStream(const IncomingStreamEvent* evt, void* ud) {
  (void)ud;
  g_stream_id = evt->streamId;
  atomic_store(&g_have_stream, 1);
}

typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  uint8_t data[4096];
  size_t len;
} ReadWaiter;

static void on_read(int ec, const ReadResponse* reply, const char* em, void* ud) {
  ReadWaiter* w = (ReadWaiter*)ud;
  w->err_code = ec;
  if (reply && reply->data.data) {
    w->len = reply->data.len < sizeof(w->data) ? reply->data.len : sizeof(w->data);
    memcpy(w->data, reply->data.data, w->len);
  }
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

// Reads the request off the accepted stream, echoes it back and releases it.
static bool serveEcho(LibP2PCtx* server) {
  if (!wait_done(&g_have_stream)) {
    fprintf(stderr, "server: no incoming stream\n");
    return false;
  }
  uint64_t streamId = g_stream_id;

  ReadWaiter rw;
  memset(&rw, 0, sizeof(rw));
  StreamReadLpRequest readReq = {streamId, EchoMaxSize};
  libp2p_ctx_stream_read_lp(server, &readReq, on_read, &rw);
  if (!wait_done(&rw.done) || rw.err_code != 0) {
    fprintf(stderr, "server read: %s\n", rw.err[0] ? rw.err : "unknown");
    return false;
  }

  BoolWaiter bw;
  NimFfiBytes payload = {rw.data, rw.len};
  StreamWriteRequest writeReq = {streamId, payload};
  bool ok = AWAIT_BOOL(bw, libp2p_ctx_stream_write_lp(server, &writeReq, on_bool, &bw),
                       "server write");
  AWAIT_BOOL(bw, libp2p_ctx_stream_release(server, streamId, on_bool, &bw),
             "server release");
  return ok;
}

typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  uint64_t streamId;
} DialWaiter;

static void on_dial(int ec, const DialResponse* reply, const char* em, void* ud) {
  DialWaiter* w = (DialWaiter*)ud;
  w->err_code = ec;
  if (reply)
    w->streamId = reply->streamId;
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

static LibP2PCtx* createNode(const char* listenAddr, const char* label) {
  NimFfiStr addrSlot = nimffi_str(listenAddr);
  Libp2pConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.addrs.data = &addrSlot;
  cfg.addrs.len = 1;
  cfg.muxer = MuxerMplex;
  cfg.transport = TransportTcp;
  return await_create(&cfg, label);
}

int main(void) {
  LibP2PCtx* server = createNode("/ip4/127.0.0.1/tcp/5013", "server");
  if (!server)
    return 1;

  // Mount before start so peers learn about the protocol during identify.
  libp2p_ctx_add_on_incoming_stream_listener(server, onIncomingStream, NULL);

  BoolWaiter bw;
  if (!AWAIT_BOOL(bw,
                  libp2p_ctx_mount_protocol(server, nimffi_str(EchoProto), on_bool, &bw),
                  "mount_protocol") ||
      !AWAIT_BOOL(bw, libp2p_ctx_start(server, on_bool, &bw), "start server")) {
    libp2p_ctx_destroy(server);
    return 1;
  }

  PeerInfoWaiter pw;
  if (!await_peerinfo(server, &pw, "peerinfo")) {
    libp2p_ctx_destroy(server);
    return 1;
  }
  printf("Echo server started: %s\n", pw.peerId);
  for (size_t i = 0; i < pw.naddrs; i++)
    printf("  %s\n", pw.addrs[i]);

  LibP2PCtx* client = createNode("/ip4/127.0.0.1/tcp/0", "client");
  if (!client) {
    libp2p_ctx_destroy(server);
    return 1;
  }

  int status = 1;
  if (!AWAIT_BOOL(bw, libp2p_ctx_start(client, on_bool, &bw), "start client"))
    goto cleanup;

  // Establish the peer connection first, then open a protocol stream via dial.
  NimFfiStr connAddrs[16];
  for (size_t i = 0; i < pw.naddrs; i++)
    connAddrs[i] = nimffi_str(pw.addrs[i]);
  ConnectRequest connReq = {nimffi_str(pw.peerId), {connAddrs, pw.naddrs}, 0};
  if (!AWAIT_BOOL(bw, libp2p_ctx_connect(client, &connReq, on_bool, &bw), "connect"))
    goto cleanup;

  DialWaiter dw;
  memset(&dw, 0, sizeof(dw));
  DialRequest dialReq = {nimffi_str(pw.peerId), nimffi_str(EchoProto)};
  libp2p_ctx_dial(client, &dialReq, on_dial, &dw);
  if (!wait_done(&dw.done) || dw.err_code != 0) {
    fprintf(stderr, "dial: %s\n", dw.err[0] ? dw.err : "unknown");
    goto cleanup;
  }
  uint64_t streamId = dw.streamId;

  const char* sent = "hello from cbind echo";
  printf("Client sending: %s\n", sent);
  NimFfiBytes sentBytes = {(uint8_t*)sent, strlen(sent)};
  StreamWriteRequest writeReq = {streamId, sentBytes};
  if (!AWAIT_BOOL(bw, libp2p_ctx_stream_write_lp(client, &writeReq, on_bool, &bw),
                  "stream_write_lp"))
    goto cleanup;

  // The server side runs on this thread too: read the request and echo it back
  // before the client reads the reply.
  if (!serveEcho(server))
    goto cleanup;

  ReadWaiter rw;
  memset(&rw, 0, sizeof(rw));
  StreamReadLpRequest readReq = {streamId, EchoMaxSize};
  libp2p_ctx_stream_read_lp(client, &readReq, on_read, &rw);
  if (!wait_done(&rw.done) || rw.err_code != 0) {
    fprintf(stderr, "stream_read_lp: %s\n", rw.err[0] ? rw.err : "unknown");
    goto cleanup;
  }
  printf("Client received: %.*s\n", (int)rw.len, (const char*)rw.data);

  if (rw.len == strlen(sent) && memcmp(rw.data, sent, rw.len) == 0)
    status = 0;
  else
    fprintf(stderr, "Error: echoed payload did not match\n");

  AWAIT_BOOL(bw, libp2p_ctx_stream_close_with_eof(client, streamId, on_bool, &bw),
             "stream_close_with_eof");
  AWAIT_BOOL(bw, libp2p_ctx_stream_release(client, streamId, on_bool, &bw),
             "stream_release");

cleanup:
  AWAIT_BOOL(bw, libp2p_ctx_stop(client, on_bool, &bw), "stop client");
  AWAIT_BOOL(bw, libp2p_ctx_stop(server, on_bool, &bw), "stop server");
  libp2p_ctx_destroy(client);
  libp2p_ctx_destroy(server);
  return status;
}
