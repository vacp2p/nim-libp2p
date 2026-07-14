// Metrics: two TCP nodes connect, then one dumps the process-wide Prometheus
// registry as JSON via libp2p_ctx_collect_metrics. The registry is global (it
// belongs to the `metrics` module, not a single node), so a running node with a
// live connection is enough to populate real counters. The generated bindings
// are asynchronous, so every call is wrapped with the blocking helpers in
// common.h.
#include "common.h"

// TransportType / MuxerType ordinals, mirrored from libp2p_ffi/config.nim.
static const int64_t TransportTcp = 1;
static const int64_t MuxerMplex = 0;

// collect_metrics replies with a JSON string (Result[string]), so it needs its
// own waiter. The document can be large, so keep a generous buffer and record
// whether it was truncated for display.
typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  char json[1 << 16];
  size_t len;
  bool truncated;
} MetricsWaiter;

static void on_metrics(int ec, const NimFfiStr *reply, const char *em,
                       void *ud) {
  MetricsWaiter *w = (MetricsWaiter *)ud;
  w->err_code = ec;
  if (reply && reply->data) {
    size_t cap = sizeof(w->json) - 1;
    w->truncated = reply->len > cap;
    w->len = w->truncated ? cap : reply->len;
    memcpy(w->json, reply->data, w->len);
    w->json[w->len] = '\0';
  }
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

static LibP2PCtx *createNode(const char *listenAddr, const char *label) {
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
  LibP2PCtx *server = createNode("/ip4/127.0.0.1/tcp/5041", "server");
  LibP2PCtx *client = createNode("/ip4/127.0.0.1/tcp/5042", "client");
  if (!server || !client) {
    libp2p_ctx_destroy(server);
    libp2p_ctx_destroy(client);
    return 1;
  }

  int status = 1;
  BoolWaiter bw;
  if (!AWAIT_BOOL(bw, libp2p_ctx_start(server, on_bool, &bw), "start server") ||
      !AWAIT_BOOL(bw, libp2p_ctx_start(client, on_bool, &bw), "start client"))
    goto cleanup;

  PeerInfoWaiter pw;
  if (!await_peerinfo(server, &pw, "peerinfo"))
    goto cleanup;

  NimFfiStr connAddrs[MAX_ADDRS];
  for (size_t i = 0; i < pw.naddrs; i++)
    connAddrs[i] = nimffi_str(pw.addrs[i]);
  ConnectRequest connReq = {nimffi_str(pw.peerId), {connAddrs, pw.naddrs}, 0};
  if (!AWAIT_BOOL(bw, libp2p_ctx_connect(client, &connReq, on_bool, &bw),
                  "connect"))
    goto cleanup;

  // Let identify and the muxer settle so their counters are non-zero.
  sleep_ms(500);

  MetricsWaiter mw;
  memset(&mw, 0, sizeof(mw));
  libp2p_ctx_collect_metrics(server, on_metrics, &mw);
  if (!wait_done(&mw.done) || mw.err_code != 0) {
    fprintf(stderr, "collect_metrics: %s\n", mw.err[0] ? mw.err : "unknown");
    goto cleanup;
  }

  // The payload is a JSON array of {name,type,help,labels,value,timestamp}
  // objects. Print a short prefix rather than the whole document.
  printf("Collected %zu bytes of metrics%s\n", mw.len,
         mw.truncated ? " (truncated)" : "");
  printf("%.512s%s\n", mw.json, mw.len > 512 ? " ..." : "");

  // A running node always registers libp2p collectors, so a well-formed,
  // non-empty JSON array with at least one named metric is the success signal.
  if (mw.len > 2 && mw.json[0] == '[' && strstr(mw.json, "\"name\""))
    status = 0;
  else
    fprintf(stderr, "Error: metrics payload was empty or malformed\n");

cleanup:
  AWAIT_BOOL(bw, libp2p_ctx_stop(client, on_bool, &bw), "stop client");
  AWAIT_BOOL(bw, libp2p_ctx_stop(server, on_bool, &bw), "stop server");
  libp2p_ctx_destroy(client);
  libp2p_ctx_destroy(server);
  return status;
}
