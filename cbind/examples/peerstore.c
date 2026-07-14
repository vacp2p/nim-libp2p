// Peerstore: a node's local book of what it knows about other peers. This
// example drives the store directly — no dialing required — by taking a second
// node's real PeerInfo and then adding, inspecting, updating and removing it
// through the peerstore API. The generated bindings are asynchronous, so every
// call is wrapped with the blocking helpers in common.h.
#include "common.h"

// TransportType / MuxerType ordinals, mirrored from libp2p_ffi/config.nim.
static const int64_t TransportTcp = 1;
static const int64_t MuxerMplex = 0;

static const char *CustomProto = "/cbind/peerstore/1.0.0";

// get_peers replies with a PeersResponse of peer-id strings.
#define MAX_PEERS 16
typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  char peerIds[MAX_PEERS][128];
  size_t n;
} PeersWaiter;

static void on_peers(int ec, const PeersResponse *reply, const char *em,
                     void *ud) {
  PeersWaiter *w = (PeersWaiter *)ud;
  w->err_code = ec;
  if (reply) {
    w->n = reply->peerIds.len < MAX_PEERS ? reply->peerIds.len : MAX_PEERS;
    for (size_t i = 0; i < w->n; i++)
      if (reply->peerIds.data[i].data)
        snprintf(w->peerIds[i], sizeof(w->peerIds[i]), "%s",
                 reply->peerIds.data[i].data);
  }
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

// get_peer_info replies with the full PeerStoreEntryResponse for one peer.
typedef struct {
  atomic_int done;
  int err_code;
  char err[256];
  char addrs[MAX_ADDRS][256];
  size_t naddrs;
  char protocols[MAX_ADDRS][128];
  size_t nprotocols;
} PeerEntryWaiter;

static void on_peer_entry(int ec, const PeerStoreEntryResponse *reply,
                          const char *em, void *ud) {
  PeerEntryWaiter *w = (PeerEntryWaiter *)ud;
  w->err_code = ec;
  if (reply) {
    w->naddrs = reply->addrs.len < MAX_ADDRS ? reply->addrs.len : MAX_ADDRS;
    for (size_t i = 0; i < w->naddrs; i++)
      if (reply->addrs.data[i].data)
        snprintf(w->addrs[i], sizeof(w->addrs[i]), "%s",
                 reply->addrs.data[i].data);
    w->nprotocols =
        reply->protocols.len < MAX_ADDRS ? reply->protocols.len : MAX_ADDRS;
    for (size_t i = 0; i < w->nprotocols; i++)
      if (reply->protocols.data[i].data)
        snprintf(w->protocols[i], sizeof(w->protocols[i]), "%s",
                 reply->protocols.data[i].data);
  }
  if (em)
    snprintf(w->err, sizeof(w->err), "%s", em);
  atomic_store(&w->done, 1);
}

static bool get_entry(LibP2PCtx *ctx, const char *peerId, PeerEntryWaiter *w) {
  memset(w, 0, sizeof(*w));
  libp2p_ctx_peerstore_get_peer_info(ctx, nimffi_str(peerId), on_peer_entry, w);
  if (!wait_done(&w->done) || w->err_code != 0) {
    fprintf(stderr, "get_peer_info: %s\n", w->err[0] ? w->err : "unknown");
    return false;
  }
  return true;
}

static bool has_protocol(const PeerEntryWaiter *w, const char *proto) {
  for (size_t i = 0; i < w->nprotocols; i++)
    if (strcmp(w->protocols[i], proto) == 0)
      return true;
  return false;
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
  int status = 1;
  BoolWaiter bw;

  // The "local" node owns the peerstore we drive. The "other" node only exists
  // to hand us a real peer id and listen addresses to store.
  LibP2PCtx *local = createNode("/ip4/127.0.0.1/tcp/5051", "local");
  LibP2PCtx *other = createNode("/ip4/127.0.0.1/tcp/5052", "other");
  if (!local || !other) {
    libp2p_ctx_destroy(local);
    libp2p_ctx_destroy(other);
    return 1;
  }

  // Start `other` so its listen addresses are bound and reported by peer_info.
  if (!AWAIT_BOOL(bw, libp2p_ctx_start(other, on_bool, &bw), "start other"))
    goto cleanup;

  PeerInfoWaiter other_info;
  if (!await_peerinfo(other, &other_info, "other peerinfo"))
    goto cleanup;
  printf("Peer to store: %s\n", other_info.peerId);

  // ── add_peer: merge addresses (and a protocol) into the address book ───────
  NimFfiStr addrs[MAX_ADDRS];
  for (size_t i = 0; i < other_info.naddrs; i++)
    addrs[i] = nimffi_str(other_info.addrs[i]);
  NimFfiStr protoSlot = nimffi_str(CustomProto);
  AddPeerRequest addReq = {nimffi_str(other_info.peerId),
                           {addrs, other_info.naddrs},
                           {&protoSlot, 1}};
  if (!AWAIT_BOOL(bw,
                  libp2p_ctx_peerstore_add_peer(local, &addReq, on_bool, &bw),
                  "add_peer"))
    goto cleanup;
  printf("Added %s with %zu address(es) and protocol %s\n", other_info.peerId,
         other_info.naddrs, CustomProto);

  // ── get_peers: the stored peer should now be listed ───────────────────────
  PeersWaiter peers;
  memset(&peers, 0, sizeof(peers));
  libp2p_ctx_peerstore_get_peers(local, on_peers, &peers);
  if (!wait_done(&peers.done) || peers.err_code != 0) {
    fprintf(stderr, "get_peers: %s\n", peers.err[0] ? peers.err : "unknown");
    goto cleanup;
  }
  bool listed = false;
  printf("Peerstore holds %zu peer(s):\n", peers.n);
  for (size_t i = 0; i < peers.n; i++) {
    printf("  %s\n", peers.peerIds[i]);
    if (strcmp(peers.peerIds[i], other_info.peerId) == 0)
      listed = true;
  }
  if (!listed) {
    fprintf(stderr, "Error: stored peer not found in get_peers\n");
    goto cleanup;
  }

  // ── get_peer_info: read back the stored addresses and protocols ───────────
  PeerEntryWaiter entry;
  if (!get_entry(local, other_info.peerId, &entry))
    goto cleanup;
  printf("Stored entry: %zu address(es), %zu protocol(s)\n", entry.naddrs,
         entry.nprotocols);
  if (entry.naddrs == 0 || !has_protocol(&entry, CustomProto)) {
    fprintf(stderr, "Error: stored entry is missing its address or protocol\n");
    goto cleanup;
  }

  // ── set_peer_protocols: replace the protocol set, then verify the change ──
  const char *NewProto = "/cbind/peerstore/2.0.0";
  NimFfiStr newProtoSlot = nimffi_str(NewProto);
  SetProtocolsRequest setReq = {nimffi_str(other_info.peerId),
                                {&newProtoSlot, 1}};
  if (!AWAIT_BOOL(
          bw,
          libp2p_ctx_peerstore_set_peer_protocols(local, &setReq, on_bool, &bw),
          "set_peer_protocols"))
    goto cleanup;
  if (!get_entry(local, other_info.peerId, &entry))
    goto cleanup;
  if (has_protocol(&entry, CustomProto) || !has_protocol(&entry, NewProto)) {
    fprintf(stderr,
            "Error: set_peer_protocols did not replace the protocols\n");
    goto cleanup;
  }
  printf("Protocols replaced with %s\n", NewProto);

  // ── delete_peer: the store should be empty of it afterwards ───────────────
  if (!AWAIT_BOOL(bw,
                  libp2p_ctx_peerstore_delete_peer(
                      local, nimffi_str(other_info.peerId), on_bool, &bw),
                  "delete_peer"))
    goto cleanup;
  memset(&peers, 0, sizeof(peers));
  libp2p_ctx_peerstore_get_peers(local, on_peers, &peers);
  if (!wait_done(&peers.done) || peers.err_code != 0) {
    fprintf(stderr, "get_peers: %s\n", peers.err[0] ? peers.err : "unknown");
    goto cleanup;
  }
  for (size_t i = 0; i < peers.n; i++) {
    if (strcmp(peers.peerIds[i], other_info.peerId) == 0) {
      fprintf(stderr, "Error: peer still present after delete_peer\n");
      goto cleanup;
    }
  }
  printf("Deleted %s from the peerstore\n", other_info.peerId);
  status = 0;

cleanup:
  AWAIT_BOOL(bw, libp2p_ctx_stop(other, on_bool, &bw), "stop other");
  libp2p_ctx_destroy(other);
  libp2p_ctx_destroy(local);
  return status;
}
