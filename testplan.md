# Kademlia DHT Test Plan

## Overview

This test plan covers nim-libp2p's Kademlia DHT implementation - a distributed hash table for peer routing and content discovery. The focus is on protocol compliance with the [libp2p Kademlia DHT specification](https://github.com/libp2p/specs/tree/master/kad-dht), correct routing table management, and reliable RPC message handling.

**Protocol ID:** `/ipfs/kad/1.0.0`

---

## Specification Constants (RFC Compliance)

Per the specification, the following parameters MUST be used:

| Constant | Value | Description |
|----------|-------|-------------|
| k (replication) | 20 | Peers per k-bucket, replication factor |
| α (concurrency) | 10 | Maximum concurrent lookup requests |
| Key size | 256 bits | SHA-256 hash output |
| Distance metric | XOR | `XOR(sha256(key1), sha256(key2))` |
| Bootstrap interval | 10 minutes | Periodic routing table refresh |
| Query timeout | 10 seconds | Maximum RPC query wait time |
| Provider republish | 22 hours | Provider record refresh interval |
| Provider expiration | 48 hours | Provider record TTL |
| Routing table refresh | 30 minutes | k-bucket refresh interval |

---

## 1. Distance & Key Handling

### 1.1 XOR Distance Metric

- ✅ **TC1.1.1**: Verify XOR distance of identical keys is zero (implies CPL = 256).
- ✅ **TC1.1.2**: Verify distance comparison correctly orders peers by closeness to target.

### 1.2 Common Prefix Length (CPL)

- ✅ **TC1.2.1**: Verify CPL calculation for keys differing in first bit returns 0.
- ✅ **TC1.2.2**: Verify countLeadingZeroBits helper function.

### 1.3 Key Conversion

- ✅ **TC1.3.1**: Verify PeerID to DHT key conversion using SHA-256.
- ✅ **TC1.3.2**: Verify CID to DHT key conversion (multihash extraction).
- ✅ **TC1.3.3**: Verify arbitrary byte array key hashing.

---

## 2. Routing Table & Bootstrap

### 2.1 K-Bucket Management

- ✅ **TC2.1.1**: Verify peer insertion into correct k-bucket based on CPL.
- ✅ **TC2.1.2**: Verify k-bucket does not exceed k (20) peers.
- 😃 **TC2.1.3**: Verify peer update moves peer to tail (most recently seen).
- ✅ **TC2.1.4**: Verify k-bucket eviction policy when full (LRU with liveness check).
- 😃 **TC2.1.5**: Verify self peer ID is never added to routing table.

### 2.2 Peer Lifecycle

- 😃 **TC2.2.1**: Verify peer addition updates last-seen timestamp.
- ✅ **TC2.2.2**: Verify `findClosestPeers(key, n)` returns n closest peers by XOR distance.
- 😃 **TC2.2.3**: Verify `findClosestPeers` with fewer than n peers returns all available.
- ❌ **TC2.2.4**: Verify peer lookup by PeerID returns correct peer info.

### 2.3 Server vs Client Mode

**⚠️ NOT IMPLEMENTED: Current implementation adds all peers to routing table regardless of mode.**

- ❌ **TC2.3.1**: Verify server mode peers are added to routing table.
- ❌ **TC2.3.2**: Verify client mode peers are NOT added to routing table.
- ❌ **TC2.3.3**: Verify node mode detection via identify protocol.
- ❌ **TC2.3.4**: Verify client mode node can still query DHT.
- ❌ **TC2.3.5**: Verify mode transition from client to server updates routing table eligibility.
- ❌ **TC2.3.6**: Verify server mode is advertised via identify protocol.

### 2.4 Bootstrap & Refresh

- ✅ **TC2.4.1**: Verify k-bucket refresh triggers lookup for random key in bucket range.
- ✅ **TC2.4.2**: Verify stale peers are removed during refresh.
- ❌ **TC2.4.3**: Verify refresh does not affect recently-active buckets.
- 😃 **TC2.4.4**: Verify bootstrap runs on node startup.
- ❌ **TC2.4.5**: Verify bootstrap generates random PeerID for each non-empty bucket.
- ❌ **TC2.4.6**: Verify bootstrap performs lookup for each random ID.
- ❌ **TC2.4.7**: Verify bootstrap includes self-lookup.
**(NOTE: used by `dispatchFindNode` to bootstrap nodes only, not `findNode` as a network-wide search)**
- ❌ **TC2.4.8**: Verify periodic bucket refresh at configured interval (default: 10min).
- ❌ **TC2.4.9**: Verify bucket refresh interval is configurable via `bucketRefreshTime`.
- ❌ **TC2.4.10**: Verify bucket refresh respects query timeout.
- ❌ **TC2.4.11**: Verify bucket refresh with no peers handles gracefully.
- ❌ **TC2.4.12**: Verify connection to configured bootstrap peers.
- ❌ **TC2.4.13**: Verify bootstrap peer multiaddress validation.
- ❌ **TC2.4.14**: Verify bootstrap continues if some peers unreachable.

---

## 3. RPC Messages & Transport

### 3.1 Message Serialization

- ❌ **TC3.1.1**: Verify message serialization produces valid protobuf.
- ✅ **TC3.1.2**: Verify message deserialization round-trip preserves all fields.
- ❌ **TC3.1.3**: Verify length prefix is unsigned varint per multiformats spec.
- ✅ **TC3.1.4**: Verify malformed protobuf returns error.
- ❌ **TC3.1.5**: Verify truncated message returns error.

### 3.2 Message Type Handling

- ✅ **TC3.2.1**: Verify unknown message type returns error.
- ✅ **TC3.2.2**: Verify PING request/response round-trip (deprecated but functional).

### 3.3 Peer Info Serialization

- ✅ **TC3.3.1**: Verify PeerInfo includes PeerID and multiaddresses.
- ❌ **TC3.3.2**: Verify PeerInfo with multiple multiaddresses.
- ✅ **TC3.3.3**: Verify PeerInfo with no multiaddresses.
- ✅ **TC3.3.4**: Verify PeerInfo deserialization with invalid PeerID returns error.
- ✅ **TC3.3.5**: Verify invalid connection type in Peer returns error.

### 3.4 Connection Type Field

**⚠️ Note: Connection type field is defined in protobuf but not actively used in current implementation.**

- ❌ **TC3.4.1**: Verify NOT_CONNECTED (0) is default value.
- ❌ **TC3.4.2**: Verify CONNECTED (1) indicates live connection.
- ❌ **TC3.4.3**: Verify CAN_CONNECT (2) indicates recent successful connection.
- ❌ **TC3.4.4**: Verify CANNOT_CONNECT (3) indicates repeated failures.

---

## 4. DHT Operations

### 4.1 FIND_NODE

- ❌ **TC4.1.1**: Verify FIND_NODE request with valid PeerID key.
- ❌ **TC4.1.2**: Verify FIND_NODE response contains k closest peers.
- ❌ **TC4.1.3**: Verify FIND_NODE response excludes querying peer.
- ❌ **TC4.1.4**: Verify FIND_NODE with empty key returns error.
- ❌ **TC4.1.5**: Verify FIND_NODE for own PeerID returns k closest peers.
- ❌ **TC4.1.6**: Verify closerPeers field contains valid PeerInfo entries.
- ❌ **TC4.1.7**: Verify response with more than k peers is handled gracefully.
- ✅ **TC4.1.8**: Verify response peers are added to routing table (if server mode).
- ✅ **TC4.1.9**: Verify empty closerPeers response is valid.

### 4.2 Value Records

- ✅ **TC4.2.1**: Verify PUT_VALUE stores record at target peer.
- ❌ **TC4.2.2**: Verify PUT_VALUE key matches Record.key.
- ❌ **TC4.2.3**: Verify PUT_VALUE response echoes request.
- ❌ **TC4.2.4**: Verify PUT_VALUE with mismatched keys returns error.
- ✅ **TC4.2.5**: Verify PUT_VALUE validation runs before storage.
- ✅ **TC4.2.6**: Verify GET_VALUE returns stored record if present.
- ❌ **TC4.2.7**: Verify GET_VALUE returns k closest peers if record not found.
- ❌ **TC4.2.8**: Verify GET_VALUE returns both record and closest peers when available.
- ❌ **TC4.2.9**: Verify GET_VALUE validates returned records.
- ❌ **TC4.2.10**: Verify GET_VALUE rejects record where Record.key does not match requested key.
- ✅ **TC4.2.11**: Verify GET_VALUE fails when quorum not achieved.
- ❌ **TC4.2.12**: Verify GET_VALUE succeeds when quorum achieved with mixed valid/invalid responses.
- ❌ **TC4.2.13**: Verify GET_VALUE handles quorum > number of available peers.
- ❌ **TC4.2.14**: Verify GET_VALUE handles peers dropping mid-query (quorum recalculation).
- ❌ **TC4.2.15**: Verify GET_VALUE with quorum=1 returns first valid response.
- ❌ **TC4.2.16**: Verify record value field stores arbitrary bytes (binary data, unicode, null bytes).
- ✅ **TC4.2.17**: Verify timeReceived is set by receiver in RFC3339 format.
- ✅ **TC4.2.18**: Verify record serialization/deserialization round-trip.
- ✅ **TC4.2.19**: Verify correction PUT_VALUE sent to peers with outdated records.
- ✅ **TC4.2.20**: Verify correction PUT_VALUE sent to peers with no record but close to key.
- ✅ **TC4.2.21**: Verify correction uses best record from lookup.

### 4.3 Record Validation

- ❌ **TC4.3.1**: Verify Validate() accepts valid record.
- ❌ **TC4.3.2**: Verify Validate() runs on GET_VALUE retrieval.
- ✅ **TC4.3.3**: Verify Validate() runs on PUT_VALUE before storage.
- ✅ **TC4.3.4**: Verify custom validator can be registered.
- ❌ **TC4.3.5**: Verify Select() with equal records returns consistent choice.
- ❌ **TC4.3.6**: Verify Select() is deterministic (same inputs always return same index across multiple calls).
- ✅ **TC4.3.7**: Verify custom selector can be registered.

### 4.4 Provider Records

- ✅ **TC4.4.1**: Verify ADD_PROVIDER stores provider record.
- ❌ **TC4.4.2**: Verify ADD_PROVIDER validates sender PeerID matches providerPeers.
- ❌ **TC4.4.3**: Verify ADD_PROVIDER rejects mismatched PeerID.
- ❌ **TC4.4.4**: Verify ADD_PROVIDER with CID key (multihash extraction).
- ❌ **TC4.4.5**: Verify multiple providers for same CID.
- ❌ **TC4.4.6**: Verify ADD_PROVIDER updates existing provider record.
- ✅ **TC4.4.7**: Verify GET_PROVIDERS returns known providers for CID.
- ❌ **TC4.4.8**: Verify GET_PROVIDERS returns k closest peers.
- ✅ **TC4.4.9**: Verify GET_PROVIDERS with no providers returns only peers.
- ❌ **TC4.4.10**: Verify GET_PROVIDERS returns both providers and peers when available.
- ❌ **TC4.4.11**: Verify GET_PROVIDERS uses multihash for CID convergence.
- ✅ **TC4.4.12**: Verify provider record expiration after configured interval (spec: 48h, impl default: 30min).
- ✅ **TC4.4.13**: Verify provider record refresh resets expiration timer.
- ✅ **TC4.4.14**: Verify provider republish at configured interval (spec: 22h, impl default: 10min).
- ✅ **TC4.4.15**: Verify expired provider records are not returned.
- ❌ **TC4.4.16**: Verify provider address storage policy (may omit addresses).

---

## 5. Peer & Content Routing

### 5.1 Iterative Lookup

- ❌ **TC5.1.1**: Verify lookup initializes with k closest from routing table.
- ❌ **TC5.1.2**: Verify lookup queries α (10) peers concurrently.
- ❌ **TC5.1.3**: Verify lookup adds returned peers to candidate list.
- ❌ **TC5.1.4**: Verify lookup excludes already-queried peers from candidates.
- ❌ **TC5.1.5**: Verify lookup terminates when k closest nodes responded.
- ❌ **TC5.1.6**: Verify lookup terminates when all known nodes queried.
- ❌ **TC5.1.7**: Verify candidate list remains sorted by XOR distance.
- ❌ **TC5.1.8**: Verify lookup respects configured query timeout (spec: 10s, impl default: 5s).
- ❌ **TC5.1.9**: Verify lookup continues on individual peer timeout.
- ❌ **TC5.1.10**: Verify lookup returns partial results on overall timeout.
- ❌ **TC5.1.11**: Verify lookup with empty routing table returns empty result.
- ❌ **TC5.1.12**: Verify lookup handles peer returning itself in closerPeers (loop prevention).
- ❌ **TC5.1.13**: Verify lookup handles peer returning querying node in closerPeers.
- ❌ **TC5.1.14**: Verify lookup handles peer returning duplicate entries in closerPeers.
- ❌ **TC5.1.15**: Verify lookup handles peer returning invalid/malformed PeerInfo.

### 5.2 FindPeer Operation

- ✅ **TC5.2.1**: Verify FindPeer returns peer info for known peer.
- ✅ **TC5.2.2**: Verify FindPeer performs iterative lookup for unknown peer.
- ✅ **TC5.2.3**: Verify FindPeer returns error for non-existent peer.
- ❌ **TC5.2.4**: Verify FindPeer terminates early when target found.

### 5.3 Content Routing

- ❌ **TC5.3.1**: Verify Provide locates k closest peers to CID.
- ✅ **TC5.3.2**: Verify Provide sends ADD_PROVIDER to k closest peers.
- ❌ **TC5.3.3**: Verify Provide includes local multiaddresses.
- ❌ **TC5.3.4**: Verify Provide handles partial failures gracefully.
- ✅ **TC5.3.5**: Verify FindProviders returns known providers.
- ❌ **TC5.3.6**: Verify FindProviders performs iterative lookup.
- ❌ **TC5.3.7**: Verify FindProviders aggregates providers from multiple peers.
- ❌ **TC5.3.8**: Verify FindProviders deduplicates provider entries.
- ❌ **TC5.3.9**: Verify FindProviders terminates when sufficient providers found.

---

## 6. Integration Tests

### 6.1 Basic DHT Operations

- ✅ **TC6.1.1**: Verify multi-node DHT peer discovery via FIND_NODE (2-node direct, 3+ node transitive).
- ✅ **TC6.1.2**: Verify PUT_VALUE/GET_VALUE round-trip across network.
- ✅ **TC6.1.3**: Verify provider announcement and discovery.
- ✅ **TC6.1.4**: Verify FindPeer for peer not in routing table.

### 6.2 Churn Handling

- ❌ **TC6.2.1**: Verify routing table updates on peer join (via bootstrap, FIND_NODE responses).
- ❌ **TC6.2.2**: Verify record replication survives peer churn.
- ❌ **TC6.2.3**: Verify lookup completes with high churn rate.

### 6.3 Concurrent Operations

- ❌ **TC6.3.1**: Verify multiple concurrent lookups.
- ❌ **TC6.3.2**: Verify concurrent PUT_VALUE and GET_VALUE.
- ❌ **TC6.3.3**: Verify concurrent provider announcements.
- ❌ **TC6.3.4**: Verify no deadlocks under high concurrency.

### 6.4 Error Scenarios

- ❌ **TC6.4.1**: Verify graceful handling when all bootstrap peers unreachable.
- ❌ **TC6.4.2**: Verify PUT_VALUE when k closest peers unreachable.
- ❌ **TC6.4.3**: Verify GET_VALUE with corrupted responses.

---

## 7. Edge Cases & Error Handling

### 7.1 Malicious Node Behavior

- ❌ **TC7.1.1**: Verify handling of peer never responding.
- ❌ **TC7.1.2**: Verify handling of peer returning excessive data.

### 7.2 Resource Limits

- ✅ **TC7.2.1**: Verify maximum provider records per CID.

### 7.3 Edge Cases

- ❌ **TC7.3.1**: Verify behavior with single node (no peers).
- ❌ **TC7.3.2**: Verify behavior when routing table is full.
- ❌ **TC7.3.3**: Verify lookup for key with no nearby peers.
