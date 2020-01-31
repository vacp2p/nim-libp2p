import options
import strutils
import tables
import chronos
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
  PingHandler* = proc(data: seq[byte]): Future[void] {.gcsafe.}

  KadPeer = ref object of RootObj
    peerInfo: PeerInfo
  KBucket = seq[KadPeer] # should be k length
  #KBucket = array[k, KadPeer] # should be k length
  KBuckets = array[b, KBucket] # should be k length
  KadProto* = ref object of LPProtocol # declare a custom protocol
    peerInfo: PeerInfo # this peer's info, should be b length
    kbuckets: KBuckets # should be b length

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

method init(p: KadProto) =
  #{.base, gcsafe, async.} =
  # handle incoming connections in closure
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    # main handler that gets triggered on connection for protocol string
    echo "Got from remote - ", cast[string](await conn.readLp())
    await conn.writeLp("Hello!")
    await conn.close()
    # await p.handleConn(conn, proto)

  p.handler = handle # set proto handler
  p.codec = KadCodec # init proto with the correct string id

method start*(p: KadProto) {.async, base.} =
  # start kad
  discard

method stop*(p: KadProto) {.async, base.} =
  # stop kad
  discard

# XXX: Property of Kad protocol...I think this is right
# Not switch level concern, or is it?
method addContact(p: KadProto, contact: PeerInfo) {.base, gcsafe.} =
  echo("addContact ", contact)
  var index = p.which_kbucket(contact)
  echo("which kbucket ", index)

  var kadPeer = KadPeer(peerInfo: contact)
  p.kbuckets[index].add(kadPeer)

# XXX: If we want this, move elsewhere
#proc createSwitch(ma: MultiAddress): (Switch, PeerInfo) =
#  ## Helper to create a swith
#
#  let seckey = PrivateKey.random(RSA) # use a random key for peer id
#  var peerInfo = PeerInfo.init(seckey) # create a peer id and assign
#  peerInfo.addrs.add(ma) # set this peer's multiaddresses (can be any number)
#
#  let identify = newIdentify(peerInfo) # create the identify proto
#
#  proc createMplex(conn: Connection): Muxer =
#    # helper proc to create multiplexers,
#    # use this to perform any custom setup up,
#    # such as adjusting timeout or anything else
#    # that the muxer requires
#    result = newMplex(conn)
#
#  let mplexProvider = newMuxerProvider(createMplex, MplexCodec) # create multiplexer
#  let transports = @[Transport(newTransport(TcpTransport))] # add all transports (tcp only for now, but can be anything in the future)
#  let muxers = {MplexCodec: mplexProvider}.toTable() # add all muxers
#  let secureManagers = {SecioCodec: Secure(newSecio(seckey))}.toTable() # setup the secio and any other secure provider
#
#  # Add kadProto field to Switch type as optional? This is how pubsub works
#  # let kadProto = KadProto newKad(peerInfo)
#
#  let switch = newSwitch(peerInfo,
#                         transports,
#                         identify,
#                         muxers,
#                         secureManagers)
#  result = (switch, peerInfo)
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

#  var nodes = generateNodes(4)
#  var awaiters: seq[Future[void]]
#  awaiters.add((await nodes[0].start()))
#  awaiters.add((await nodes[1].start()))
#  awaiters.add((await nodes[2].start()))
#  # XXX: start this later?
#  awaiters.add((await nodes[3].start()))
#
  # I want nodes[0] to add other nodes as contacts
  #await addContacts(nodes[0], nodes)
  # await

  # echo("NYI")
  # TODO: Let's generate 10 nodes
  # TODO: HERE ATM - FIND NODE
  # TODO: Add many contacts
  # TODO: Pluggable shorter id too
  #
  # If we generate N nodes there, what do we have?
  # same multiaddress (essentially)
  # what about peer info and peer id?
  # Lets try this separately from above
  #generateNodes(n: Natural): seq[Switch]

#waitFor(mainGen())

# TODO: Methods for ping, store, find_node and find_value

# XXX: subscribeToPeer takes connection, not peerId
method ping*(p: KadProto,
             peerInfo: PeerInfo,
             handler: PingHandler) {.base, async.} =
  # ping a peer to see if they are online
  echo("*** NYI: ping ", peerInfo)

  # Fake, not from dial
  #echo "Got from remote - ", cast[string](await conn.readLp())
  #handler(cast[byte]"xxx")

  # TODO: We want to use handler here for whatever happens
  #
  #for peer in p.peers.values:
  #  await p.sendSubs(peer, @[topic], true)

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
