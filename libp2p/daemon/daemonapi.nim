## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implementes API for `go-libp2p-daemon`.
import os, osproc, strutils, tables, streams, strtabs
import asyncdispatch2
import ../varint, ../multiaddress, ../protobuf/minprotobuf, ../base58

when not defined(windows):
  import posix

const
  DefaultSocketPath* = "/tmp/p2pd.sock"
  DefaultSocketPattern* = "/tmp/p2pd-$1.sock"
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

  PSRequestType* {.pure.} = enum
    GET_TOPICS = 0,
    LIST_PEERS = 1,
    PUBLISH = 2,
    SUBSCRIBE = 3

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

  PeerID* = seq[byte]
  MultiProtocol* = string
  CID* = seq[byte]
  LibP2PPublicKey* = seq[byte]
  DHTValue* = seq[byte]

  P2PStreamFlags* {.pure.} = enum
    None, Closed, Inbound, Outbound

  P2PDaemonFlags* {.pure.} = enum
    DHTClient, DHTFull, Bootstrap,
    Logging, Verbose,
    PSFloodSub, PSGossipSub, PSSign, PSStrictSign

  P2PStream* = ref object
    flags*: set[P2PStreamFlags]
    peer*: PeerID
    raddress*: MultiAddress
    protocol*: string
    transp*: StreamTransport

  P2PServer = object
    server*: StreamServer
    address*: TransportAddress

  DaemonAPI* = ref object
    # pool*: TransportPool
    flags*: set[P2PDaemonFlags]
    address*: TransportAddress
    sockname*: string
    pattern*: string
    ucounter*: int
    process*: Process
    handlers*: Table[string, P2PStreamCallback]
    servers*: seq[P2PServer]
    log*: string
    loggerFut*: Future[void]

  PeerInfo* = object
    peer*: PeerID
    addresses*: seq[MultiAddress]

  PubsubTicket* = ref object
    topic*: string
    handler*: P2PPubSubCallback
    transp*: StreamTransport

  PubSubMessage* = object
    peer*: PeerID
    data*: seq[byte]
    seqno*: seq[byte]
    topics*: seq[string]
    signature*: seq[byte]
    key*: seq[byte]

  P2PStreamCallback* = proc(api: DaemonAPI,
                            stream: P2PStream): Future[void] {.gcsafe.}
  P2PPubSubCallback* = proc(api: DaemonAPI,
                            ticket: PubsubTicket,
                            message: PubSubMessage): Future[bool] {.gcsafe.}

  DaemonRemoteError* = object of Exception
  DaemonLocalError* = object of Exception


var daemonsCount {.threadvar.}: int

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

proc requestPSGetTopics(): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/pubsub.go
  ## Processing function `doPubsubGetTopics(req *pb.PSRequest)`.
  let msgid = cast[uint](PSRequestType.GET_TOPICS)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.PUBSUB)))
  result.write(initProtoField(8, msg))
  result.finish()

proc requestPSListPeers(topic: string): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/pubsub.go
  ## Processing function `doPubsubListPeers(req *pb.PSRequest)`.
  let msgid = cast[uint](PSRequestType.LIST_PEERS)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, topic))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.PUBSUB)))
  result.write(initProtoField(8, msg))
  result.finish()

proc requestPSPublish(topic: string, data: openarray[byte]): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/pubsub.go
  ## Processing function `doPubsubPublish(req *pb.PSRequest)`.
  let msgid = cast[uint](PSRequestType.PUBLISH)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, topic))
  msg.write(initProtoField(3, data))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.PUBSUB)))
  result.write(initProtoField(8, msg))
  result.finish()

proc requestPSSubscribe(topic: string): ProtoBuffer =
  ## https://github.com/libp2p/go-libp2p-daemon/blob/master/pubsub.go
  ## Processing function `doPubsubSubscribe(req *pb.PSRequest)`.
  let msgid = cast[uint](PSRequestType.SUBSCRIBE)
  result = initProtoBuffer({WithVarintLength})
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, msgid))
  msg.write(initProtoField(2, topic))
  msg.finish()
  result.write(initProtoField(1, cast[uint](RequestType.PUBSUB)))
  result.write(initProtoField(8, msg))
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
  try:
    for i in 0..<len(buffer):
      await conn.readExactly(addr buffer[i], 1)
      res = PB.getUVarint(buffer.toOpenArray(0, i), length, size)
      if res == VarintStatus.Success:
        break
    if res != VarintStatus.Success or size > MaxMessageSize:
      buffer.setLen(0)
    buffer.setLen(size)
    await conn.readExactly(addr buffer[0], int(size))
  except TransportIncompleteError:
    buffer.setLen(0)

  result = buffer

proc newConnection*(api: DaemonAPI): Future[StreamTransport] =
  # echo "Establish new connection to daemon [", $api.address, "]"
  result = connect(api.address)

proc closeConnection*(api: DaemonAPI, transp: StreamTransport) {.async.} =
  # echo "Close connection with daemon [", $api.address, "]"
  transp.close()
  await transp.join()

proc socketExists(filename: string): bool =
  var res: Stat
  result = stat(filename, res) >= 0'i32

proc loggingHandler(api: DaemonAPI): Future[void] =
  var retFuture = newFuture[void]("logging.handler")
  var loop = getGlobalDispatcher()
  let fd = wrapAsyncSocket(SocketHandle(api.process.outputHandle))
  proc readOutputLoop(udata: pointer) {.gcsafe.} =
    var buffer: array[2048, char]
    let res = posix.read(cint(fd), addr buffer[0], 2000)
    if res == -1 or res == 0:
      removeReader(fd)
      retFuture.complete()
    else:
      var cstr = cast[cstring](addr buffer[0])
      api.log.add(cstr)
      # let offset = len(api.log)
      # api.log.setLen(offset + res)
      # copyMem(addr api.log[offset], addr buffer[0], res)
  addReader(fd, readOutputLoop, nil)
  result = retFuture

proc newDaemonApi*(flags: set[P2PDaemonFlags] = {},
                   bootstrapNodes: seq[string] = @[],
                   id: string = "",
                   daemon = DefaultDaemonFile,
                   sockpath = DefaultSocketPath,
                   pattern = "/tmp/nim-p2pd-$1.sock",
                   poolSize = 10,
                   gossipsubHeartbeatInterval = 0,
                   gossipsubHeartbeatDelay = 0): Future[DaemonAPI] {.async.} =
  ## Initialize connections to `go-libp2p-daemon` control socket.
  var api = new DaemonAPI
  var args = newSeq[string]()
  var env: StringTableRef

  api.flags = flags
  api.servers = newSeq[P2PServer]()
  api.pattern = pattern
  api.ucounter = 1
  api.handlers = initTable[string, P2PStreamCallback]()
  api.sockname = sockpath

  if api.sockname == DefaultSocketPath:
    # If client not specify `sockpath` but tries to spawn many daemons, we will
    # replace sockname.
    if daemonsCount != 0:
      api.sockname = DefaultSocketPattern % [$daemonsCount]

  api.address = initTAddress(api.sockname)
  inc(daemonsCount)

  # We will start daemon process only when control socket path is not default or
  # options are specified.
  if flags == {} and api.sockname == DefaultSocketPath:
    discard
  else:
    # DHTFull and DHTClient could not be present at the same time
    if P2PDaemonFlags.DHTFull in flags and P2PDaemonFlags.DHTClient in flags:
      api.flags.excl(DHTClient)
    # PSGossipSub and PSFloodSub could not be present at the same time
    if P2PDaemonFlags.PSGossipSub in flags and
       P2PDaemonFlags.PSFloodSub in flags:
      api.flags.excl(PSFloodSub)
    if P2PDaemonFlags.DHTFull in api.flags:
      args.add("-dht")
    if P2PDaemonFlags.DHTClient in api.flags:
      args.add("-dhtClient")
    if P2PDaemonFlags.Bootstrap in api.flags:
      args.add("-b")
    if P2PDaemonFlags.Verbose in api.flags:
      env = newStringTable("IPFS_LOGGING", "debug", modeCaseSensitive)
    if P2PDaemonFlags.PSGossipSub in api.flags:
      args.add("-pubsub")
      args.add("-pubsubRouter=gossipsub")
      if gossipsubHeartbeatInterval != 0:
        let param = $gossipsubHeartbeatInterval & "ms"
        args.add("-gossipsubHeartbeatInterval=" & param)
      if gossipsubHeartbeatDelay != 0:
        let param = $gossipsubHeartbeatDelay & "ms"
        args.add("-gossipsubHeartbeatInitialDelay=" & param)
    if P2PDaemonFlags.PSFloodSub in api.flags:
      args.add("-pubsub")
      args.add("-pubsubRouter=floodsub")
    if api.flags * {P2PDaemonFlags.PSFloodSub, P2PDaemonFlags.PSFloodSub} != {}:
      if P2PDaemonFlags.PSSign in api.flags:
        args.add("-pubsubSign=true")
      if P2PDaemonFlags.PSStrictSign in api.flags:
        args.add("-pubsubSignStrict=true")
    if len(bootstrapNodes) > 0:
      args.add("-bootstrapPeers=" & bootstrapNodes.join(","))
    if len(id) != 0:
      args.add("-id=" & id)
    if api.sockname != DefaultSocketPath:
      args.add("-sock=" & api.sockname)

  # We are trying to get absolute daemon path.
  let cmd = findExe(daemon)
  if len(cmd) == 0:
    raise newException(DaemonLocalError, "Could not find daemon executable!")
  # We will try to remove control socket file, because daemon will fail
  # if its not able to create new socket control file.
  # We can't use `existsFile()` because it do not support unix-domain socket
  # endpoints.
  if socketExists(api.sockname):
    if not tryRemoveFile(api.sockname):
      if api.sockname != sockpath:
        raise newException(DaemonLocalError, "Socket is already bound!")
  # Starting daemon process
  # echo "Spawn [", cmd, " ", args.join(" "), "]"
  api.process = startProcess(cmd, "", args, env, {poStdErrToStdOut})
  # Waiting until daemon will not be bound to control socket.
  while true:
    if not api.process.running():
      echo api.process.errorStream.readAll()
      raise newException(DaemonLocalError,
                         "Daemon executable could not be started!")
    if socketExists(api.sockname):
      break
    await sleepAsync(100)
  # api.pool = await newPool(api.address, poolsize = poolSize)
  if P2PDaemonFlags.Logging in api.flags:
    api.loggerFut = loggingHandler(api)
  result = api

proc close*(stream: P2PStream) {.async.} =
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
  # await api.pool.close()
  # Closing all pending servers.
  if len(api.servers) > 0:
    var pending = newSeq[Future[void]]()
    for server in api.servers:
      server.server.stop()
      server.server.close()
      pending.add(server.server.join())
    await all(pending)
    for server in api.servers:
      discard tryRemoveFile($(server.address))
    api.servers.setLen(0)
  # Closing daemon's process.
  api.process.kill()
  discard api.process.waitForExit()
  # Waiting for logger loop to exit
  if not isNil(api.loggerFut):
    await api.loggerFut
  # Attempt to delete control socket endpoint.
  if socketExists(api.sockname):
    discard tryRemoveFile(api.sockname)

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
  if len(message) == 0:
    raise newException(DaemonLocalError, "Incorrect or empty message received!")
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
  var transp = await api.newConnection()
  try:
    var pb = await transactMessage(transp, requestIdentity())
    pb.withMessage() do:
      let res = pb.enterSubmessage()
      if res == cast[int](ResponseType.IDENTITY):
        result = pb.getPeerInfo()
  finally:
    await api.closeConnection(transp)

proc connect*(api: DaemonAPI, peer: PeerID,
              addresses: seq[MultiAddress],
              timeout = 0) {.async.} =
  ## Connect to remote peer with id ``peer`` and addresses ``addresses``.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestConnect(peer, addresses,
                                                         timeout))
    pb.withMessage() do:
      discard
  finally:
    await api.closeConnection(transp)

proc disconnect*(api: DaemonAPI, peer: PeerID) {.async.} =
  ## Disconnect from remote peer with id ``peer``.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestDisconnect(peer))
    pb.withMessage() do:
      discard
  finally:
    await api.closeConnection(transp)

proc openStream*(api: DaemonAPI, peer: PeerID,
                 protocols: seq[string],
                 timeout = 0): Future[P2PStream] {.async.} =
  ## Open new stream to peer ``peer`` using one of the protocols in
  ## ``protocols``. Returns ``StreamTransport`` for the stream.
  var transp = await api.newConnection()
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
    await api.closeConnection(transp)
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
  var transp = await api.newConnection()
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
      api.servers.add(P2PServer(server: server, address: localaddr))
  except:
    for item in protocols:
      api.handlers.del(item)
    server.stop()
    server.close()
    await server.join()
    raise getCurrentException()
  finally:
    await api.closeConnection(transp)

proc listPeers*(api: DaemonAPI): Future[seq[PeerInfo]] {.async.} =
  ## Get list of remote peers to which we are currently connected.
  var transp = await api.newConnection()
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
    await api.closeConnection(transp)

proc cmTagPeer*(api: DaemonAPI, peer: PeerID, tag: string,
              weight: int) {.async.} =
  ## Tag peer with id ``peer`` using ``tag`` and ``weight``.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestCMTagPeer(peer, tag, weight))
    withMessage(pb) do:
      discard
  finally:
    await api.closeConnection(transp)

proc cmUntagPeer*(api: DaemonAPI, peer: PeerID, tag: string) {.async.} =
  ## Remove tag ``tag`` from peer with id ``peer``.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestCMUntagPeer(peer, tag))
    withMessage(pb) do:
      discard
  finally:
    await api.closeConnection(transp)

proc cmTrimPeers*(api: DaemonAPI) {.async.} =
  ## Trim all connections.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestCMTrim())
    withMessage(pb) do:
      discard
  finally:
    await api.closeConnection(transp)

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

proc enterPsMessage(pb: var ProtoBuffer) {.inline.} =
  var res = pb.enterSubmessage()
  if res != cast[int](ResponseType.PUBSUB):
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
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestDHTFindPeer(peer, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.VALUE)
      result = pb.dhtGetSinglePeerInfo()
  finally:
    await api.closeConnection(transp)

proc dhtGetPublicKey*(api: DaemonAPI, peer: PeerID,
                      timeout = 0): Future[LibP2PPublicKey] {.async.} =
  ## Get peer's public key from peer with id ``peer``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestDHTGetPublicKey(peer, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.VALUE)
      result = pb.dhtGetSingleValue()
  finally:
    await api.closeConnection(transp)

proc dhtGetValue*(api: DaemonAPI, key: string,
                  timeout = 0): Future[seq[byte]] {.async.} =
  ## Get value associated with ``key``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestDHTGetValue(key, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.VALUE)
      result = pb.dhtGetSingleValue()
  finally:
    await api.closeConnection(transp)

proc dhtPutValue*(api: DaemonAPI, key: string, value: seq[byte],
                  timeout = 0) {.async.} =
  ## Associate ``value`` with ``key``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestDHTPutValue(key, value,
                                                             timeout))
    withMessage(pb) do:
      discard
  finally:
    await api.closeConnection(transp)

proc dhtProvide*(api: DaemonAPI, cid: CID, timeout = 0) {.async.} =
  ## Provide content with id ``cid``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestDHTProvide(cid, timeout))
    withMessage(pb) do:
      discard
  finally:
    await api.closeConnection(transp)

proc dhtFindPeersConnectedToPeer*(api: DaemonAPI, peer: PeerID,
                                 timeout = 0): Future[seq[PeerInfo]] {.async.} =
  ## Find peers which are connected to peer with id ``peer``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  var list = newSeq[PeerInfo]()
  try:
    let spb = requestDHTFindPeersConnectedToPeer(peer, timeout)
    var pb = await transp.transactMessage(spb)
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        if len(message) == 0:
          break
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSinglePeerInfo())
      result = list
  finally:
    await api.closeConnection(transp)

proc dhtGetClosestPeers*(api: DaemonAPI, key: string,
                         timeout = 0): Future[seq[PeerID]] {.async.} =
  ## Get closest peers for ``key``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  var list = newSeq[PeerID]()
  try:
    let spb = requestDHTGetClosestPeers(key, timeout)
    var pb = await transp.transactMessage(spb)
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        if len(message) == 0:
          break
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSingleValue())
      result = list
  finally:
    await api.closeConnection(transp)

proc dhtFindProviders*(api: DaemonAPI, cid: CID, count: uint32,
                       timeout = 0): Future[seq[PeerInfo]] {.async.} =
  ## Get ``count`` providers for content with id ``cid``.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  var list = newSeq[PeerInfo]()
  try:
    let spb = requestDHTFindProviders(cid, count, timeout)
    var pb = await transp.transactMessage(spb)
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        if len(message) == 0:
          break
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSinglePeerInfo())
      result = list
  finally:
    await api.closeConnection(transp)

proc dhtSearchValue*(api: DaemonAPI, key: string,
                     timeout = 0): Future[seq[seq[byte]]] {.async.} =
  ## Search for value with ``key``, return list of values found.
  ##
  ## You can specify timeout for DHT request with ``timeout`` value. ``0`` value
  ## means no timeout.
  var transp = await api.newConnection()
  var list = newSeq[seq[byte]]()
  try:
    var pb = await transp.transactMessage(requestDHTSearchValue(key, timeout))
    withMessage(pb) do:
      pb.enterDhtMessage(DHTResponseType.BEGIN)
      while true:
        var message = await transp.recvMessage()
        if len(message) == 0:
          break
        var cpb = initProtoBuffer(message)
        if cpb.getDhtMessageType() == DHTResponseType.END:
          break
        list.add(cpb.dhtGetSingleValue())
      result = list
  finally:
    await api.closeConnection(transp)

proc pubsubGetTopics*(api: DaemonAPI): Future[seq[string]] {.async.} =
  ## Get list of topics this node is subscribed to.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestPSGetTopics())
    withMessage(pb) do:
      pb.enterPsMessage()
      var topics = newSeq[string]()
      var topic = ""
      while pb.getString(1, topic) != -1:
        topics.add(topic)
        topic.setLen(0)
      result = topics
  finally:
    await api.closeConnection(transp)

proc pubsubListPeers*(api: DaemonAPI,
                      topic: string): Future[seq[PeerID]] {.async.} =
  ## Get list of peers we are connected to and which also subscribed to topic
  ## ``topic``.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestPSListPeers(topic))
    withMessage(pb) do:
      pb.enterPsMessage()
      var peers = newSeq[PeerID]()
      var peer = newSeq[byte]()
      while pb.getBytes(2, peer) != -1:
        peers.add(peer)
        peer.setLen(0)
      result = peers
  finally:
    await api.closeConnection(transp)

proc pubsubPublish*(api: DaemonAPI, topic: string,
                    value: seq[byte]) {.async.} =
  ## Get list of peer identifiers which are subscribed to topic ``topic``.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestPSPublish(topic, value))
    withMessage(pb) do:
      discard
  finally:
    await api.closeConnection(transp)

proc getPubsubMessage*(pb: var ProtoBuffer): PubSubMessage =
  var item = newSeq[byte]()
  for field in 1..6:
    while true:
      if pb.getBytes(field, item) == -1:
        break
      if field == 1:
        result.peer = item
      elif field == 2:
        result.data = item
      elif field == 3:
        result.seqno = item
      elif field == 4:
        var copyitem = item
        var stritem = cast[string](copyitem)
        if len(result.topics) == 0:
          result.topics = newSeq[string]()
        result.topics.add(stritem)
      elif field == 5:
        result.signature = item
      elif field == 6:
        result.key = item
      item.setLen(0)

proc pubsubLoop(api: DaemonAPI, ticket: PubsubTicket) {.async.} =
  while true:
    var pbmessage = await ticket.transp.recvMessage()
    if len(pbmessage) == 0:
      break
    var pb = initProtoBuffer(pbmessage)
    var message = pb.getPubsubMessage()
    ## We can do here `await` too
    let res = await ticket.handler(api, ticket, message)
    if not res:
      ticket.transp.close()
      await ticket.transp.join()
      break

proc pubsubSubscribe*(api: DaemonAPI, topic: string,
                   handler: P2PPubSubCallback): Future[PubsubTicket] {.async.} =
  ## Subscribe to topic ``topic``.
  var transp = await api.newConnection()
  try:
    var pb = await transp.transactMessage(requestPSSubscribe(topic))
    pb.withMessage() do:
      var ticket = new PubsubTicket
      ticket.topic = topic
      ticket.handler = handler
      ticket.transp = transp
      asyncCheck pubsubLoop(api, ticket)
      result = ticket
  except:
    await api.closeConnection(transp)
    raise getCurrentException()

proc `$`*(pinfo: PeerInfo): string =
  ## Get string representation of ``PeerInfo`` object.
  result = newStringOfCap(128)
  result.add("{PeerID: '")
  result.add(Base58.encode(pinfo.peer))
  result.add("' Addresses: [")
  let length = len(pinfo.addresses)
  for i in 0..<length:
    result.add("'")
    result.add($pinfo.addresses[i])
    result.add("'")
    if i < length - 1:
      result.add(", ")
  result.add("]}")
  if len(pinfo.addresses) > 0:
    result = result
