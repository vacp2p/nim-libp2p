## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implementes API for `go-libp2p-daemon`.
import os, osproc, strutils, tables, streams
import asyncdispatch2
import ../varint, ../multiaddress, ../protobuf/minprotobuf, transpool

when not defined(windows):
  import posix

const
  DefaultSocketPath* = "/tmp/p2pd.sock"
  DefaultDaemonFile* = "p2pd"

type
  RequestType* {.pure.} = enum
    IDENTITY = 0,
    CONNECT = 1,
    STREAM_OPEN = 2,
    STREAM_HANDLER = 3,
    DHT = 4,
    LIST_PEERS = 5,
    CONNMANAGER = 6,
    DISCONNECT = 7
    PUBSUB = 8

  DHTRequestType* {.pure.} = enum
    FIND_PEER = 0,
    FIND_PEERS_CONNECTED_TO_PEER = 1,
    FIND_PROVIDERS = 2,
    GET_CLOSEST_PEERS = 3,
    GET_PUBLIC_KEY = 4,
    GET_VALUE = 5,
    SEARCH_VALUE = 6,
    PUT_VALUE = 7,
    PROVIDE = 8

  ConnManagerRequestType* {.pure.} = enum
    TAG_PEER = 0,
    UNTAG_PEER = 1,
    TRIM = 2

  ResponseKind* = enum
    Malformed,
    Error,
    Success

  ResponseType* {.pure.} = enum
    ERROR = 2,
    STREAMINFO = 3,
    IDENTITY = 4,
    DHT = 5,
    PEERINFO = 6
    PUBSUB = 7

  DHTResponseType* {.pure.} = enum
    BEGIN = 0,
    VALUE = 1,
    END = 2

  PSResponseType* {.pure.} = enum
    GET_TOPIC = 0,
    LIST_PEERS = 1,
    PUBLISH = 2,
    SUBSCRIBE = 3

  PeerID* = seq[byte]
  MultiProtocol* = string
  # MultiAddress* = seq[byte]
  CID* = seq[byte]
  LibP2PPublicKey* = seq[byte]
  DHTValue* = seq[byte]

  P2PStreamFlags* {.pure.} = enum
    None, Closed, Inbound, Outbound

  P2PDaemonFlags* {.pure.} = enum
    DHTClient, DHTFull, Bootstrap

  P2PStream* = ref object
    flags*: set[P2PStreamFlags]
    peer*: PeerID
    raddress*: MultiAddress
    protocol*: string
    transp*: StreamTransport

  DaemonAPI* = ref object
    pool*: TransportPool
    flags*: set[P2PDaemonFlags]
    address*: TransportAddress
    sockname*: string
    pattern*: string
    ucounter*: int
    process*: Process
    handlers*: Table[string, P2PStreamCallback]
    servers*: seq[StreamServer]

  PeerInfo* = object
    peer*: PeerID
    addresses*: seq[MultiAddress]

  P2PStreamCallback* = proc(api: DaemonAPI,
                            stream: P2PStream): Future[void] {.gcsafe.}

  DaemonRemoteError* = object of Exception
  DaemonLocalError* = object of Exception

proc requestIdentity(): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/conn.go
  ## Processing function `doIdentify(req *pb.Request)`.
  result = initProtoBuffer({WithVarintLength})
  result.write(initProtoField(1, cast[uint](RequestType.IDENTITY)))
  result.finish()

proc requestConnect(peerid: PeerID,
                    addresses: openarray[MultiAddress],
                    timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/conn.go
  ## Processing function `doConnect(req *pb.Request)`.
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, peerid))
  for item in addresses:
    msg.write(initProtoField(2, item.data.buffer))
  if timeout > 0:
    msg.write(initProtoField(3, timeout))
  result.write(initProtoField(1, cast[uint](RequestType.CONNECT)))
  result.write(initProtoField(2, msg))
  result.finish()

proc requestDisconnect(peerid: PeerID): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/conn.go
  ## Processing function `doDisconnect(req *pb.Request)`.
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, peerid))
  result.write(initProtoField(1, cast[uint](RequestType.DISCONNECT)))
  result.write(initProtoField(7, msg))
  result.finish()

proc requestStreamOpen(peerid: PeerID,
                       protocols: openarray[string],
                       timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/conn.go
  ## Processing function `doStreamOpen(req *pb.Request)`.
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, peerid))
  for item in protocols:
    msg.write(initProtoField(2, item))
  if timeout > 0:
    msg.write(initProtoField(3, timeout))
  result.write(initProtoField(1, cast[uint](RequestType.STREAM_OPEN)))
  result.write(initProtoField(3, msg))
  result.finish()

proc requestStreamHandler(path: string,
                          protocols: openarray[MultiProtocol]): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/conn.go
  ## Processing function `doStreamHandler(req *pb.Request)`.
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, path))
  for item in protocols:
    msg.write(initProtoField(2, item))
  result.write(initProtoField(1, cast[uint](RequestType.STREAM_HANDLER)))
  result.write(initProtoField(4, msg))
  result.finish()

proc requestListPeers(): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/conn.go
  ## Processing function `doListPeers(req *pb.Request)`
  result = initProtoBuffer({WithVarintLength})
  result.write(initProtoField(1, cast[uint](RequestType.LIST_PEERS)))
  result.finish()

proc requestDHTFindPeer(peer: PeerID, timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTFindPeer(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.FIND_PEER)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, peer))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTFindPeersConnectedToPeer(peer: PeerID,
                                        timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTFindPeersConnectedToPeer(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.FIND_PEERS_CONNECTED_TO_PEER)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, peer))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTFindProviders(cid: CID,
                             count: uint32, timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTFindProviders(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.FIND_PROVIDERS)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(3, cid))
  msg.write(initProtoField(6, count))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTGetClosestPeers(key: string, timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTGetClosestPeers(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.GET_CLOSEST_PEERS)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(4, key))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTGetPublicKey(peer: PeerID, timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTGetPublicKey(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.GET_PUBLIC_KEY)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, peer))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTGetValue(key: string, timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTGetValue(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.GET_VALUE)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(4, key))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTSearchValue(key: string, timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTSearchValue(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.SEARCH_VALUE)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(4, key))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTPutValue(key: string, value: openarray[byte],
                        timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTPutValue(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.PUT_VALUE)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(4, key))
  msg.write(initProtoField(5, value))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestDHTProvide(cid: CID, timeout = 0): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/dht.go
  ## Processing function `doDHTProvide(req *pb.DHTRequest)`.
  let msgid = cast[uint](DHTRequestType.PROVIDE)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(3, cid))
  if timeout > 0:
    msg.write(initProtoField(7, uint(timeout)))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.DHT)))
  result.write(initProtoField(5, msg))
  result.finish()

proc requestCMTagPeer(peer: PeerID, tag: string, weight: int): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/connmgr.go#L18
  let msgid = cast[uint](ConnManagerRequestType.TAG_PEER)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, peer))
  msg.write(initProtoField(3, tag))
  msg.write(initProtoField(4, weight))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.CONNMANAGER)))
  result.write(initProtoField(6, msg))
  result.finish()

proc requestCMUntagPeer(peer: PeerID, tag: string): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/connmgr.go#L33
  let msgid = cast[uint](ConnManagerRequestType.UNTAG_PEER)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, peer))
  msg.write(initProtoField(3, tag))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.CONNMANAGER)))
  result.write(initProtoField(6, msg))
  result.finish()

proc requestCMTrim(): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/connmgr.go#L47
  let msgid = cast[uint](ConnManagerRequestType.TRIM)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.CONNMANAGER)))
  result.write(initProtoField(6, msg))
  result.finish()

proc checkResponse(pb: var ProtoBuffer): ResponseKind {.inline.} =
  result = ResponseKind.Malformed
  var value: uint64
  if getVarintValue(pb, 1, value) > 0:
    if value == 0:
      result = ResponseKind.Success
    else:
      result = ResponseKind.Error

proc getErrorMessage(pb: var ProtoBuffer): string {.inline.} =
  if pb.enterSubmessage() == cast[int](ResponseType.ERROR):
    if pb.getString(1, result) == -1:
      raise newException(DaemonLocalError, "Error message is missing!")

proc recvMessage(conn: StreamTransport): Future[seq[byte]] {.async.} =
  var
    size: uint
    length: int
    res: VarintStatus
  var buffer = newSeq[byte](10)
  for i in 0..<len(buffer):
    await conn.readExactly(addr buffer[i], 1)
    res = PB.getUVarint(buffer.toOpenArray(0, i), length, size)
    if res == VarintStatus.Success:
      break
  if res != VarintStatus.Success or size > MaxMessageSize:
    raise newException(ValueError, "Invalid message size")
  buffer.setLen(size)
  await conn.readExactly(addr buffer[0], int(size))
  result = buffer

proc socketExists(filename: string): bool =
  var res: Stat
  result = stat(filename, res) >= 0'i32

proc newDaemonApi*(flags: set[P2PDaemonFlags] = {},
                   bootstrapNodes: seq[string] = @[],
                   id: string = "",
                   daemon = DefaultDaemonFile,
                   sockpath = DefaultSocketPath,
                   pattern = "/tmp/nim-p2pd-$1.sock",
                   poolSize = 10): Future[DaemonAPI] {.async.} =
  ## Initialize connections to `go-libp2p-daemon` control socket.
  result = new DaemonAPI
  result.flags = flags
  result.servers = newSeq[StreamServer]()
  result.address = initTAddress(sockpath)
  result.pattern = pattern
  result.ucounter = 1
  result.handlers = initTable[string, P2PStreamCallback]()
  # We will start daemon process only when control socket path is not default or
  # options are specified.
  if flags == {} and sockpath == DefaultSocketPath:
    result.pool = await newPool(initTAddress(sockpath), poolsize = poolSize)
  else:
    var args = newSeq[string]()
    # DHTFull and DHTClient could not be present at the same time
    if P2PDaemonFlags.DHTFull in flags and P2PDaemonFlags.DHTClient in flags:
      result.flags.excl(DHTClient)
    if P2PDaemonFlags.DHTFull in result.flags:
      args.add("-dht")
    if P2PDaemonFlags.DHTClient in result.flags:
      args.add("-dhtClient")
    if P2PDaemonFlags.Bootstrap in result.flags:
      args.add("-b")
    if len(bootstrapNodes) > 0:
      args.add("-bootstrapPeers=" & bootstrapNodes.join(","))
    if len(id) != 0:
      args.add("-id=" & id)
    if sockpath != DefaultSocketPath:
      args.add("-sock=" & sockpath)
    # We are trying to get absolute daemon path.
    let cmd = findExe(daemon)
    if len(cmd) == 0:
      raise newException(DaemonLocalError, "Could not find daemon executable!")
    # We will try to remove control socket file, because daemon will fail
    # if its not able to create new socket control file.
    # We can't use `existsFile()` because it do not support unix-domain socket
    # endpoints.
    if socketExists(sockpath):
      discard tryRemoveFile(sockpath)
    # Starting daemon process
    result.process = startProcess(cmd, "", args, options = {poStdErrToStdOut})
    # Waiting until daemon will not be bound to control socket.
    while true:
      if not result.process.running():
        echo result.process.errorStream.readAll()
        raise newException(DaemonLocalError,
                           "Daemon executable could not be started!")
      if socketExists(sockpath):
        break
      await sleepAsync(100)
    result.sockname = sockpath
    result.pool = await newPool(initTAddress(sockpath), poolsize = poolSize)

proc close*(api: DaemonAPI, stream: P2PStream) {.async.} =
  ## Close ``stream``.
  if P2PStreamFlags.Closed notin stream.flags:
    stream.transp.close()
    await stream.transp.join()
    stream.transp = nil
    stream.flags.incl(P2PStreamFlags.Closed)
  else:
    raise newException(DaemonLocalError, "Stream is already closed!")

proc close*(api: DaemonAPI) {.async.} =
  ## Shutdown connections to `go-libp2p-daemon` control socket.
  await api.pool.close()
  # Closing all pending servers.
  if len(api.servers) > 0:
    var pending = newSeq[Future[void]]()
    for server in api.servers:
      server.stop()
      server.close()
      pending.add(server.join())
    await all(pending)
  # Closing daemon's process.
  if api.flags != {}:
    api.process.terminate()
  # Attempt to delete control socket endpoint.
  # if socketExists(api.sockname):
  #   discard tryRemoveFile(api.sockname)

template withMessage(m, body: untyped): untyped =
  let kind = m.checkResponse()
  if kind == ResponseKind.Error:
    raise newException(DaemonRemoteError, m.getErrorMessage())
  elif kind == ResponseKind.Malformed:
    raise newException(DaemonLocalError, "Malformed message received!")
  else:
    body

proc transactMessage(transp: StreamTransport,
                     pb: ProtoBuffer): Future[ProtoBuffer] {.async.} =
  let length = pb.getLen()
  let res = await transp.write(pb.getPtr(), length)
  if res != length:
    raise newException(DaemonLocalError, "Could not send message to daemon!")
  var message = await transp.recvMessage()
  result = initProtoBuffer(message)

proc getPeerInfo(pb: var ProtoBuffer): PeerInfo =
  ## Get PeerInfo object from ``pb``.
  result.addresses = newSeq[MultiAddress]()
  result.peer = newSeq[byte]()
  if pb.getBytes(1, result.peer) == -1:
    raise newException(DaemonLocalError, "Missing required field `peer`!")
  var address = newSeq[byte]()
  while pb.getBytes(2, address) != -1:
    if len(address) != 0:
      var copyaddr = address
      result.addresses.add(MultiAddress.init(copyaddr))
      address.setLen(0)

proc identity*(api: DaemonAPI): Future[PeerInfo] {.async.} =
  ## Get Node identity information
  var transp = await api.pool.acquire()
  try:
    var pb = await transactMessage(transp, requestIdentity())
    pb.withMessage() do:
      let res = pb.enterSubmessage()
      if res == cast[int](ResponseType.IDENTITY):
        result = pb.getPeerInfo()
  finally:
    api.pool.release(transp)

proc connect*(api: DaemonAPI, peer: PeerID,
              addresses: seq[MultiAddress],
              timeout = 0) {.async.} =
  ## Connect to remote peer with id ``peer`` and addresses ``addresses``.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestConnect(peer, addresses,
                                                         timeout))
    pb.withMessage() do:
      discard
  finally:
    api.pool.release(transp)

proc disconnect*(api: DaemonAPI, peer: PeerID) {.async.} =
  ## Disconnect from remote peer with id ``peer``.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestDisconnect(peer))
    pb.withMessage() do:
      discard
  finally:
    api.pool.release(transp)

proc openStream*(api: DaemonAPI, peer: PeerID,
                 protocols: seq[string],
                 timeout = 0): Future[P2PStream] {.async.} =
  ## Open new stream to peer ``peer`` using one of the protocols in
  ## ``protocols``. Returns ``StreamTransport`` for the stream.
  var transp = await connect(api.address)
  var stream = new P2PStream
  try:
    var pb = await transp.transactMessage(requestStreamOpen(peer, protocols,
                                                            timeout))
    pb.withMessage() do:
      var res = pb.enterSubmessage()
      if res == cast[int](ResponseType.STREAMINFO):
        stream.peer = newSeq[byte]()
        var raddress = newSeq[byte]()
        stream.protocol = ""
        if pb.getLengthValue(1, stream.peer) == -1:
          raise newException(DaemonLocalError, "Missing `peer` field!")
        if pb.getLengthValue(2, raddress) == -1:
          raise newException(DaemonLocalError, "Missing `address` field!")
        stream.raddress = MultiAddress.init(raddress)
        if pb.getLengthValue(3, stream.protocol) == -1:
          raise newException(DaemonLocalError, "Missing `proto` field!")
        stream.flags.incl(Outbound)
        stream.transp = transp
        result = stream
  except:
    transp.close()
    await transp.join()
    raise getCurrentException()

proc streamHandler(server: StreamServer, transp: StreamTransport) {.async.} =
  var api = getUserData[DaemonAPI](server)
  var message = await transp.recvMessage()
  var pb = initProtoBuffer(message)
  var stream = new P2PStream
  stream.peer = newSeq[byte]()
  var raddress = newSeq[byte]()
  stream.protocol = ""
  if pb.getLengthValue(1, stream.peer) == -1:
    raise newException(DaemonLocalError, "Missing `peer` field!")
  if pb.getLengthValue(2, raddress) == -1:
    raise newException(DaemonLocalError, "Missing `address` field!")
  stream.raddress = MultiAddress.init(raddress)
  if pb.getLengthValue(3, stream.protocol) == -1:
    raise newException(DaemonLocalError, "Missing `proto` field!")
  stream.flags.incl(Inbound)
  stream.transp = transp
  if len(stream.protocol) > 0:
    var handler = api.handlers.getOrDefault(stream.protocol)
    if not isNil(handler):
      asyncCheck handler(api, stream)

proc addHandler*(api: DaemonAPI, protocols: seq[string],
                 handler: P2PStreamCallback) {.async.} =
  ## Add stream handler ``handler`` for set of protocols ``protocols``.
  var transp = await api.pool.acquire()
  var sockname = api.pattern % [$api.ucounter]
  var localaddr = initTAddress(sockname)
  inc(api.ucounter)
  var server = createStreamServer(localaddr, streamHandler, udata = api)
  try:
    for item in protocols:
      api.handlers[item] = handler
    server.start()
    var pb = await transp.transactMessage(requestStreamHandler(sockname,
                                                               protocols))
    pb.withMessage() do:
      api.servers.add(server)
  except:
    for item in protocols:
      api.handlers.del(item)
    server.stop()
    server.close()
    await server.join()
    raise getCurrentException()
  finally:
    api.pool.release(transp)

proc listPeers*(api: DaemonAPI): Future[seq[PeerInfo]] {.async.} =
  ## Get list of remote peers to which we are currently connected.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestListPeers())
    pb.withMessage() do:
      var address = newSeq[byte]()
      result = newSeq[PeerInfo]()
      var res = pb.enterSubmessage()
      while res != 0:
        if res == cast[int](ResponseType.PEERINFO):
          var peer = pb.getPeerInfo()
          result.add(peer)
        else:
          pb.skipSubmessage()
        res = pb.enterSubmessage()
  finally:
    api.pool.release(transp)

proc cmTagPeer*(api: DaemonAPI, peer: PeerID, tag: string,
              weight: int) {.async.} =
  ## Tag peer with id ``peer`` using ``tag`` and ``weight``.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestCMTagPeer(peer, tag, weight))
    withMessage(pb) do:
      discard
  finally:
    api.pool.release(transp)

proc cmUntagPeer*(api: DaemonAPI, peer: PeerID, tag: string) {.async.} =
  ## Remove tag ``tag`` from peer with id ``peer``.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestCMUntagPeer(peer, tag))
    withMessage(pb) do:
      discard
  finally:
    api.pool.release(transp)

proc cmTrimPeers*(api: DaemonAPI) {.async.} =
  ## Trim all connections.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestCMTrim())
    withMessage(pb) do:
      discard
  finally:
    api.pool.release(transp)

proc dhtGetSinglePeerInfo(pb: var ProtoBuffer): PeerInfo =
  if pb.enterSubmessage() == 2:
    result = pb.getPeerInfo()
  else:
    raise newException(DaemonLocalError, "Missing required field `peer`!")

proc dhtGetSingleValue(pb: var ProtoBuffer): seq[byte] =
  result = newSeq[byte]()
  if pb.getLengthValue(3, result) == -1:
    raise newException(DaemonLocalError, "Missing field `value`!")

proc enterDhtMessage(pb: var ProtoBuffer, rt: DHTResponseType) {.inline.} =
  var dtype: uint
  var res = pb.enterSubmessage()
  if res == cast[int](ResponseType.DHT):
    if pb.getVarintValue(1, dtype) == 0:
      raise newException(DaemonLocalError, "Missing required DHT field `type`!")
    if dtype != cast[uint](rt):
      raise newException(DaemonLocalError, "Wrong DHT answer type! ")
  else:
    raise newException(DaemonLocalError, "Wrong message type!")

proc getDhtMessageType(pb: var ProtoBuffer): DHTResponseType {.inline.} =
  var dtype: uint
  if pb.getVarintValue(1, dtype) == 0:
    raise newException(DaemonLocalError, "Missing required DHT field `type`!")
  if dtype == cast[uint](DHTResponseType.VALUE):
    result = DHTResponseType.VALUE
  elif dtype == cast[uint](DHTResponseType.END):
    result = DHTResponseType.END
  else:
    raise newException(DaemonLocalError, "Wrong DHT answer type!")

proc dhtFindPeer*(api: DaemonAPI, peer: PeerID,
                  timeout = 0): Future[PeerInfo] {.async.} =
  ## Find peer with id ``peer`` and return peer information ``PeerInfo``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestDHTFindPeer(peer, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.VALUE)
      result = pb.dhtGetSinglePeerInfo()
  finally:
    api.pool.release(transp)

proc dhtGetPublicKey*(api: DaemonAPI, peer: PeerID,
                      timeout = 0): Future[LibP2PPublicKey] {.async.} =
  ## Get peer's public key from peer with id ``peer``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestDHTGetPublicKey(peer, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.VALUE)
      result = pb.dhtGetSingleValue()
  finally:
    api.pool.release(transp)

proc dhtGetValue*(api: DaemonAPI, key: string,
                  timeout = 0): Future[seq[byte]] {.async.} =
  ## Get value associated with ``key``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestDHTGetValue(key, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.VALUE)
      result = pb.dhtGetSingleValue()
  finally:
    api.pool.release(transp)

proc dhtPutValue*(api: DaemonAPI, key: string, value: seq[byte],
                  timeout = 0) {.async.} =
  ## Associate ``value`` with ``key``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestDHTPutValue(key, value,
                                                             timeout))
    withMessage(pb) do:
      discard
  finally:
    api.pool.release(transp)

proc dhtProvide*(api: DaemonAPI, cid: CID, timeout = 0) {.async.} =
  ## Provide content with id ``cid``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  try:
    var pb = await transp.transactMessage(requestDHTProvide(cid, timeout))
    withMessage(pb) do:
      discard
  finally:
    api.pool.release(transp)

proc dhtFindPeersConnectedToPeer*(api: DaemonAPI, peer: PeerID,
                                 timeout = 0): Future[seq[PeerInfo]] {.async.} =
  ## Find peers which are connected to peer with id ``peer``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  var list = newSeq[PeerInfo]()
  try:
    let spb = requestDHTFindPeersConnectedToPeer(peer, timeout)
    var pb = await transp.transactMessage(spb)
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSinglePeerInfo())
      result = list
  finally:
    api.pool.release(transp)

proc dhtGetClosestPeers*(api: DaemonAPI, key: string,
                         timeout = 0): Future[seq[PeerID]] {.async.} =
  ## Get closest peers for ``key``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  var list = newSeq[PeerID]()
  try:
    let spb = requestDHTGetClosestPeers(key, timeout)
    var pb = await transp.transactMessage(spb)
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSingleValue())
      result = list
  finally:
    api.pool.release(transp)

proc dhtFindProviders*(api: DaemonAPI, cid: CID, count: uint32,
                              timeout = 0): Future[seq[PeerInfo]] {.async.} =
  ## Get ``count`` providers for content with id ``cid``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  var list = newSeq[PeerInfo]()
  try:
    let spb = requestDHTFindProviders(cid, count, timeout)
    var pb = await transp.transactMessage(spb)
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSinglePeerInfo())
      result = list
  finally:
    api.pool.release(transp)

proc dhtSearchValue*(api: DaemonAPI, key: string,
                     timeout = 0): Future[seq[seq[byte]]] {.async.} =
  ## Search for value with ``key``, return list of values found.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.pool.acquire()
  var list = newSeq[seq[byte]]()
  try:
    var pb = await transp.transactMessage(requestDHTSearchValue(key, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSingleValue())
      result = list
  finally:
    api.pool.release(transp)
