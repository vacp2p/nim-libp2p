import options, strutils, tables
import chronos, chronicles
import kadpeer
import ../../../libp2p/[multistream,
                       protocols/identify,
                       connection,
                       transports/transport,
                       transports/tcptransport,
                       multiaddress,
                       peerinfo,
                       crypto/crypto,
                       peer,
                       protocols/protocol,
                       muxers/muxer,
                       muxers/mplex/mplex,
                       muxers/mplex/types,
                       protocols/secure/secio,
                       protocols/secure/secure]

const KadCodec = "/test/kademlia/1.0.0" # custom protocol string

const k = 2 # maximum number of peers in bucket, test setting, should be 20
const b = 271 # size of bits of keys used to identify nodes and data

# b is based on PeerID size: 8*34-1 = 271

# Should parameterize by b, size of bits of keys (Peer ID dependent?)
type
  # XXX
  PingHandler* = proc(data: string): Future[void] {.gcsafe.}
  KBucket = seq[KadPeer] # should be k length
  #KBucket = array[k, KadPeer] # should be k length
  KBuckets = array[b, KBucket] # should be k length
  KadProto* = ref object of LPProtocol # declare a custom protocol
    peerInfo: PeerInfo # this peer's info, should be b length
    kbuckets: KBuckets # should be b length
    peers*: Table[string, KadPeer] # peerid to peer map
    # TODO: Unclear what kind of handlers we want here
    pingHandler*: PingHandler
    # TODO: More?

proc `$`(k: KadPeer): string =
  return "<KadPeer>" & k.peerInfo.peerId.pretty

proc `$`(k: KBuckets): string =
  var skipped: string
  var bucket: Kbucket
  for i in 0..<k.len:
    bucket = k[i]
    if bucket.len != 0:
      if skipped.len != 0:
        result &= "empty buckets" & skipped & "\n"
        skipped = ""
      result &= $i & ": " & $k[i] & "\n"
    else:
      skipped = skipped & " " & $i
  if skipped.len != 0:
    result &= "empty buckets" & skipped

# Returns XOR distance as PeerID
# Assuming these are of equal length, b
# Which result type do we want here?
proc xor_distance(a, b: PeerID): PeerID =
  var data: seq[byte]
  for i in 0..<a.data.len:
    data.add(a.data[i] xor b.data[i])
  return PeerID(data: data)

# Finds kbucket to place peer in by returning most significant bit position
# Assumes bigendian and byte=uint8 (2^8-1)
# Note that PeerId 8*34 = 272, which is bigger than b=160
method which_kbucket(p: KadProto, contact: PeerInfo): int {.base.} =
  var bs: string # helper bit string
  var d = xor_distance(p.peerInfo.peerId, contact.peerId)
  for i in 0..<d.data.len:
    bs = bs & ord(d.data[i]).toBin(8)
  #echo ("bs: ", bs)
  for i in 0..bs.len:
    if bs[i] == '1':
      return bs.len - 1 - i
  # Self, not really a bucket, better error type
  return -1

# TODO: Need KadPeer here
# TODO: Generally a bunch of stuff not implemented yet
proc getPeer(p: KadProto,
             peerInfo: PeerInfo,
             proto: string): KadPeer =
  if peerInfo.id in p.peers:
    result = p.peers[peerInfo.id]
    return

  # create new Kad peer
  let peer = newKadPeer(peerInfo, proto)
  trace "created new kad peer", peerId = peer.id

  p.peers[peer.id] = peer
  peer.refs.inc # increment reference count
  result = peer

method rpcHandler*(p: KadProto,
                   peer: KadPeer,
                   rpcMsg: string) {.async, base.} =
  echo("rpcHandler")
  # XXX
  # Assuming pingmsg
  await p.pingHandler(rpcMsg)
  # how do we go from here to pnig handler?

method handleConn*(p: KadProto,
                   conn: Connection,
                   proto: string) {.base, async.} =
  # handle incoming connections
  # XXX: I would expect to see this upon dial...
  # oh wait, cause we already read it?
  #echo "Got from remote - ", cast[string](await conn.readLp())
  echo "Got from remote"
  # TODO: see pubsub/handleConn
  #await conn.writeLp("Hello!")
  #await conn.close()
  if isNil(conn.peerInfo):
    trace "no valid PeerId for peer"
    await conn.close()
    return

  # XXX: Fake rpc
  proc handler(peer: KadPeer, msg: string) {.async.} =
    echo ("peer handler")
    # call kad rpc handler
    await p.rpcHandler(peer, msg)

  let peer = p.getPeer(conn.peerInfo, proto)

  peer.handler = handler

  await peer.handle(conn) # spawn peer read loop
  # TODO: Handle cleanup, etc

method init(p: KadProto) =
  #{.base, gcsafe, async.} =
  # handle incoming connections in closure
  # TODO: First hit this, then generalize a la pubsub/handleConn
  # Whenever we get a connection this should be triggered
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    # main handler that gets triggered on connection for protocol string
    # triggered upon connection for protocol string
    await p.handleConn(conn, proto)

  p.handler = handle # set proto handler
  p.codec = KadCodec # init proto with the correct string id

method start*(p: KadProto) {.async, base.} =
  # start kad
  discard

method stop*(p: KadProto) {.async, base.} =
  # stop kad
  discard

method addContact*(p: KadProto, contact: PeerInfo) {.base, gcsafe.} =
  #echo("addContact ", contact)
  var index = p.which_kbucket(contact)
  #echo("which kbucket ", index)
  var kadPeer = KadPeer(peerInfo: contact)
  p.kbuckets[index].add(kadPeer)
  echo("Printing kbuckets")
  echo p.kbuckets

##

#
#proc mainManual() {.async, gcsafe.} =
#  let ma1: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
#  let ma2: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
#
#  var peerInfo1, peerInfo2: PeerInfo
#  var switch1, switch2: Switch
#  (switch1, peerInfo1) = createSwitch(ma1) # create node 1
#
#  # setup the custom proto
#  let kadProto = new KadProto
#  # XXX: peerInfo1 centric here
#  kadProto.init(peerInfo1) # run it's init method to perform any required initialization
#  switch1.mount(kadProto) # mount the proto
#  var switch1Fut = await switch1.start() # start the node
#
#  (switch2, peerInfo2) = createSwitch(ma2) # create node 2
#  var switch2Fut = await switch2.start() # start second node
#  let conn = await switch2.dial(switch1.peerInfo, KadCodec) # dial the first node
#
#  # XOR distance between two peers
#  echo("*** xor_distance ", xor_distance(peerInfo1.peerId, peerInfo2.peerId))
#
#  # XXX: I want to add 3rd node to 2nd
#  # XXX: Does this belong to switch or protocol?
#  kadProto.addContact(peerInfo2)
#
#  echo("Printing kbuckets")
#  echo kadProto.kbuckets
#
#  await conn.writeLp("Hello!") # writeLp send a length prefixed buffer over the wire
#  # readLp reads length prefixed bytes and returns a buffer without the prefix
#  echo "Remote responded with - ", cast[string](await conn.readLp())
#
#  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
#  await allFutures(switch1Fut & switch2Fut) # wait for all transports to shutdown
#
# proc mainGen() {.async, gcsafe.} =

#waitFor(mainGen())

# TODO: Methods for ping, store, find_node and find_value

# XXX: subscribeToPeer takes connection, not peerId
# Also, only need string I think?
method ping*(p: KadProto,
             peerInfo: PeerInfo) {.base, async.} =
  var peer = p.peers[peerInfo.id]
  await peer.send("ping")

  #for peer in p.peers.values:
  #  await p.sendSubs(peer, @[topic], true)

# XXX: Modelled after subscribe for now
method listenForPing*(p: KadProto,
                      handler: PingHandler) {.base, async.} =
  ## listen to ping requests
  ##
  ## ``handler`` - user provided proc to be triggered on ping
  # TODO
  p.pingHandler = handler

method listenToPeer*(p: KadProto,
                        conn: Connection) {.base, async.} =
  var peer = p.getPeer(conn.peerInfo, p.codec)
  trace "setting connection for peer", peerId = conn.peerInfo.id
  if not peer.isConnected:
    peer.conn = conn

  # handle connection close
  conn.closeEvent.wait()
  .addCallback do (udata: pointer = nil):
    trace "connection closed, cleaning up peer",
      peer = conn.peerInfo.id

    # TODO: similar to pubsub, lock etc
    #asyncCheck p.cleanUpHelper(peer)


# XXX: Might be overkill considering we only have one Kad type right now
proc initKad(p: KadProto) =
  # TODO: Set this up, just initTable
  # f.peers = initTable[string, PubSubPeer]()

  #var kbuckets: KBuckets
  #p.peerInfo = peerInfo
  #p.kbuckets = kbuckets

  p.init()

proc newKad*(p: typedesc[KadProto], peerInfo: PeerInfo): p =
  new result
  result.peerInfo = peerInfo
  # XXX: triggerSelf, cleanupLock?
  result.initKad()
