// Circuit relay: three TCP nodes — a relay, a destination and a source. The
// destination reserves a slot on the relay; the source then reaches it over a
// `/p2p-circuit` address and runs the same echo exchange as echo.c, but relayed
// rather than direct. Used when the source can't dial the destination directly
// (NAT, firewall, incompatible transport) but both can reach the relay.
//
// The generated bindings are asynchronous, so every call is wrapped with the
// blocking helpers in common.h. As in echo.c, the destination serves its
// incoming stream from `main` (the incoming-stream handler only hands over the
// stream id) because calling back into the library from its dispatch thread
// would deadlock.
#include "common.h"

// TransportType / MuxerType ordinals, mirrored from libp2p_ffi/config.nim.
static const int64_t TransportTcp = 1;
static const int64_t MuxerMplex = 0;

static const char *EchoProto = "/cbind/relay-echo/1.0.0";
static const int64_t EchoMaxSize = 4096;

// Single-slot hand-off from the destination's incoming-stream event to main.
static atomic_int g_have_stream = 0;
static uint64_t g_stream_id = 0;

static void onIncomingStream(const IncomingStreamEvent *evt, void *ud) {
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

static void on_read(int ec, const ReadResponse *reply, const char *em,
                    void *ud) {
  ReadWaiter *w = (ReadWaiter *)ud;
  w->err_code = ec;
  if (reply && reply->data.data) {
    w->len =
        reply->data.len < sizeof(w->data) ? reply->data.len : sizeof(w->data);
    memcpy(w->data, reply->data.data, w->len);
  }
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

// dial_circuit_relay replies with a DialResponse carrying the new stream id.
typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  uint64_t streamId;
} DialWaiter;

static void on_dial(int ec, const DialResponse *reply, const char *em,
                    void *ud) {
  DialWaiter *w = (DialWaiter *)ud;
  w->err_code = ec;
  if (reply)
    w->streamId = reply->streamId;
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

// circuit_relay_reserve replies with the reservation's relay addresses and its
// expiry (unix seconds). We only need the reservation to succeed here; the
// circuit address the source dials is built from the relay's PeerInfo below.
typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  uint64_t expireTime;
} ReserveWaiter;

static void on_reserve(int ec, const ReservationResponse *reply, const char *em,
                       void *ud) {
  ReserveWaiter *w = (ReserveWaiter *)ud;
  w->err_code = ec;
  if (reply)
    w->expireTime = reply->expireTime;
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

// Reads the request off the accepted stream, echoes it back and releases it.
// The destination side runs on `main`, just like the server in echo.c.
static bool serveEcho(LibP2PCtx *dst) {
  if (!wait_done(&g_have_stream)) {
    fprintf(stderr, "dst: no incoming stream\n");
    return false;
  }
  uint64_t streamId = g_stream_id;

  ReadWaiter rw;
  memset(&rw, 0, sizeof(rw));
  StreamReadLpRequest readReq = {streamId, EchoMaxSize};
  libp2p_ctx_stream_read_lp(dst, &readReq, on_read, &rw);
  if (!wait_done(&rw.done) || rw.err_code != 0) {
    fprintf(stderr, "dst read: %s\n", rw.err[0] ? rw.err : "unknown");
    return false;
  }

  BoolWaiter bw;
  NimFfiBytes payload = {rw.data, rw.len};
  StreamWriteRequest writeReq = {streamId, payload};
  bool ok =
      AWAIT_BOOL(bw, libp2p_ctx_stream_write_lp(dst, &writeReq, on_bool, &bw),
                 "dst write");
  AWAIT_BOOL(bw, libp2p_ctx_stream_release(dst, streamId, on_bool, &bw),
             "dst release");
  return ok;
}

// The relay is a circuit-relay server (circuitRelay); source and destination
// are relay clients (circuitRelayClient) so they can reserve slots and dial
// `/p2p-circuit` addresses.
static LibP2PCtx *relayNode(const char *listenAddr, const char *label,
                            bool asClient) {
  NimFfiStr addrSlot = nimffi_str(listenAddr);
  Libp2pConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.addrs.data = &addrSlot;
  cfg.addrs.len = 1;
  cfg.muxer = MuxerMplex;
  cfg.transport = TransportTcp;
  cfg.circuitRelay = !asClient;
  cfg.circuitRelayClient = asClient;
  return await_create(&cfg, label);
}

static bool connectTo(LibP2PCtx *from, const PeerInfoWaiter *to,
                      const char *label) {
  NimFfiStr connAddrs[MAX_ADDRS];
  for (size_t i = 0; i < to->naddrs; i++)
    connAddrs[i] = nimffi_str(to->addrs[i]);
  ConnectRequest req = {nimffi_str(to->peerId), {connAddrs, to->naddrs}, 0};
  BoolWaiter bw;
  return AWAIT_BOOL(bw, libp2p_ctx_connect(from, &req, on_bool, &bw), label);
}

int main(void) {
  int status = 1;
  BoolWaiter bw;

  LibP2PCtx *relay = relayNode("/ip4/127.0.0.1/tcp/5061", "relay", false);
  LibP2PCtx *dst = relayNode("/ip4/127.0.0.1/tcp/5062", "dst", true);
  LibP2PCtx *src = relayNode("/ip4/127.0.0.1/tcp/5063", "src", true);
  if (!relay || !dst || !src) {
    libp2p_ctx_destroy(relay);
    libp2p_ctx_destroy(dst);
    libp2p_ctx_destroy(src);
    return 1;
  }

  libp2p_ctx_add_on_incoming_stream_listener(dst, onIncomingStream, NULL);

  // Mount the echo protocol on dst before starting so it is advertised, then
  // start all three nodes.
  if (!AWAIT_BOOL(
          bw,
          libp2p_ctx_mount_protocol(dst, nimffi_str(EchoProto), on_bool, &bw),
          "mount_protocol") ||
      !AWAIT_BOOL(bw, libp2p_ctx_start(relay, on_bool, &bw), "start relay") ||
      !AWAIT_BOOL(bw, libp2p_ctx_start(dst, on_bool, &bw), "start dst") ||
      !AWAIT_BOOL(bw, libp2p_ctx_start(src, on_bool, &bw), "start src"))
    goto cleanup;

  PeerInfoWaiter relayInfo, dstInfo;
  if (!await_peerinfo(relay, &relayInfo, "relay peerinfo") ||
      !await_peerinfo(dst, &dstInfo, "dst peerinfo"))
    goto cleanup;
  if (relayInfo.naddrs == 0) {
    fprintf(stderr, "Error: relay has no listen address\n");
    goto cleanup;
  }
  printf("Relay: %s\n", relayInfo.peerId);
  printf("Dst:   %s\n", dstInfo.peerId);

  // Dst connects to the relay and reserves a slot so the relay will forward
  // circuit traffic addressed to it.
  if (!connectTo(dst, &relayInfo, "dst -> relay"))
    goto cleanup;

  NimFfiStr relayAddrs[MAX_ADDRS];
  for (size_t i = 0; i < relayInfo.naddrs; i++)
    relayAddrs[i] = nimffi_str(relayInfo.addrs[i]);
  CircuitRelayReserveRequest resReq = {nimffi_str(relayInfo.peerId),
                                       {relayAddrs, relayInfo.naddrs}};
  ReserveWaiter resw;
  memset(&resw, 0, sizeof(resw));
  libp2p_ctx_circuit_relay_reserve(dst, &resReq, on_reserve, &resw);
  if (!wait_done(&resw.done) || resw.err_code != 0) {
    fprintf(stderr, "reserve: %s\n", resw.err[0] ? resw.err : "unknown");
    goto cleanup;
  }
  printf("Dst reserved a relay slot (expires at unix %llu)\n",
         (unsigned long long)resw.expireTime);

  // The circuit address the source dials: the relay's transport address, its
  // peer id, then /p2p-circuit. The source connects to the relay implicitly
  // while dialing it.
  char circuit[512];
  snprintf(circuit, sizeof(circuit), "%s/p2p/%s/p2p-circuit",
           relayInfo.addrs[0], relayInfo.peerId);
  printf("Src dialing dst via: %s\n", circuit);

  DialWaiter dw;
  memset(&dw, 0, sizeof(dw));
  DialCircuitRelayRequest dialReq = {nimffi_str(dstInfo.peerId),
                                     nimffi_str(circuit), nimffi_str(EchoProto),
                                     0};
  libp2p_ctx_dial_circuit_relay(src, &dialReq, on_dial, &dw);
  if (!wait_done(&dw.done) || dw.err_code != 0) {
    fprintf(stderr, "dial_circuit_relay: %s\n", dw.err[0] ? dw.err : "unknown");
    goto cleanup;
  }
  uint64_t streamId = dw.streamId;

  const char *sent = "hello over the relay";
  printf("Src sending: %s\n", sent);
  NimFfiBytes sentBytes = {(uint8_t *)sent, strlen(sent)};
  StreamWriteRequest writeReq = {streamId, sentBytes};
  if (!AWAIT_BOOL(bw, libp2p_ctx_stream_write_lp(src, &writeReq, on_bool, &bw),
                  "stream_write_lp"))
    goto cleanup;

  // The destination serves the relayed stream on this thread, then the source
  // reads the echo back.
  if (!serveEcho(dst))
    goto cleanup;

  ReadWaiter rw;
  memset(&rw, 0, sizeof(rw));
  StreamReadLpRequest readReq = {streamId, EchoMaxSize};
  libp2p_ctx_stream_read_lp(src, &readReq, on_read, &rw);
  if (!wait_done(&rw.done) || rw.err_code != 0) {
    fprintf(stderr, "stream_read_lp: %s\n", rw.err[0] ? rw.err : "unknown");
    goto cleanup;
  }
  printf("Src received: %.*s\n", (int)rw.len, (const char *)rw.data);

  if (rw.len == strlen(sent) && memcmp(rw.data, sent, rw.len) == 0)
    status = 0;
  else
    fprintf(stderr, "Error: relayed echo did not match\n");

  AWAIT_BOOL(bw, libp2p_ctx_stream_close_with_eof(src, streamId, on_bool, &bw),
             "stream_close_with_eof");
  AWAIT_BOOL(bw, libp2p_ctx_stream_release(src, streamId, on_bool, &bw),
             "stream_release");

cleanup:
  AWAIT_BOOL(bw, libp2p_ctx_stop(src, on_bool, &bw), "stop src");
  AWAIT_BOOL(bw, libp2p_ctx_stop(dst, on_bool, &bw), "stop dst");
  AWAIT_BOOL(bw, libp2p_ctx_stop(relay, on_bool, &bw), "stop relay");
  libp2p_ctx_destroy(src);
  libp2p_ctx_destroy(dst);
  libp2p_ctx_destroy(relay);
  return status;
}
