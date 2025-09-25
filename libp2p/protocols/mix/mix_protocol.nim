import chronicles, chronos, sequtils, strutils, os, results, sets
import std/[strformat, tables], metrics
import
  ./[
    curve25519, fragmentation, mix_message, mix_node, sphinx, serialization,
    tag_manager, mix_metrics, exit_layer, multiaddr,
  ]
import stew/endians2
import ../protocol
import ../../stream/[connection, lpstream]
import ../../[switch, multicodec, peerinfo]

const MixProtocolID* = "/mix/1.0.0"

type
  SURBIdentifierGroup = ref object
    members: HashSet[SURBIdentifier]

  ConnCreds = object
    igroup: SURBIdentifierGroup
    incoming: AsyncQueue[seq[byte]]
    surbSecret: serialization.Secret
    surbKey: serialization.Key

## Mix Protocol defines a decentralized anonymous message routing layer for libp2p networks.
## It enables sender anonymity by routing each message through a decentralized mix overlay 
## network composed of participating libp2p nodes, known as mix nodes. Each message is 
## routed independently in a stateless manner, allowing other libp2p protocols to selectively 
## anonymize messages without modifying their core protocol behavior.
type MixProtocol* = ref object of LPProtocol
  mixNodeInfo: MixNodeInfo
  pubNodeInfo: Table[PeerId, MixPubInfo]
  switch: Switch
  tagManager: TagManager
  exitLayer: ExitLayer
  rng: ref HmacDrbgContext
  # TODO: verify if this requires cleanup for cases in which response never arrives (and connection is closed)
  connCreds: Table[SURBIdentifier, ConnCreds]
  destReadBehavior: TableRef[string, destReadBehaviorCb]

proc hasDestReadBehavior*(mixProto: MixProtocol, codec: string): bool =
  return mixProto.destReadBehavior.hasKey(codec)

proc registerDestReadBehavior*(
    mixProto: MixProtocol, codec: string, fwdBehavior: destReadBehaviorCb
) =
  mixProto.destReadBehavior[codec] = fwdBehavior

proc loadAllButIndexMixPubInfo*(
    index, numNodes: int, pubInfoFolderPath: string = "./pubInfo"
): Result[Table[PeerId, MixPubInfo], string] =
  var pubInfoTable = initTable[PeerId, MixPubInfo]()
  for i in 0 ..< numNodes:
    if i == index:
      continue
    let pubInfo = MixPubInfo.readFromFile(i, pubInfoFolderPath).valueOr:
      return err("Failed to load pub info from file: " & error)
    pubInfoTable[pubInfo.peerId] = pubInfo
  return ok(pubInfoTable)

proc cryptoRandomInt(rng: ref HmacDrbgContext, max: int): Result[int, string] =
  if max == 0:
    return err("Max cannot be zero.")
  let res = rng[].generate(uint64) mod uint64(max)
  ok(res.int)

proc handleMixNodeConnection(
    mixProto: MixProtocol, conn: Connection
) {.async: (raises: [LPStreamError, CancelledError]).} =
  let receivedBytes =
    try:
      await conn.readLp(PacketSize)
    except CancelledError as exc:
      raise exc
    finally:
      await conn.close()

  if receivedBytes.len == 0:
    mix_messages_error.inc(labelValues = ["Intermediate/Exit", "NO_DATA"])
    return # No data, end of stream

  # Process the packet
  let (peerId, multiAddr, _, mixPrivKey, _, _) = mixProto.mixNodeInfo.get()

  let sphinxPacket = SphinxPacket.deserialize(receivedBytes).valueOr:
    error "Sphinx packet deserialization error", err = error
    mix_messages_error.inc(labelValues = ["Intermediate/Exit", "INVALID_SPHINX"])
    return

  let processedSP = processSphinxPacket(sphinxPacket, mixPrivKey, mixProto.tagManager).valueOr:
    error "Failed to process Sphinx packet", err = error
    mix_messages_error.inc(labelValues = ["Intermediate/Exit", "INVALID_SPHINX"])
    return

  case processedSP.status
  of Exit:
    mix_messages_recvd.inc(labelValues = ["Exit"])

    # This is the exit node, forward to destination
    let msgChunk = MessageChunk.deserialize(processedSP.messageChunk).valueOr:
      error "Deserialization failed", err = error
      mix_messages_error.inc(labelValues = ["Exit", "INVALID_SPHINX"])
      return

    let unpaddedMsg = msgChunk.removePadding().valueOr:
      error "Unpadding message failed", err = error
      mix_messages_error.inc(labelValues = ["Exit", "INVALID_SPHINX"])
      return

    let deserialized = MixMessage.deserialize(unpaddedMsg).valueOr:
      error "Deserialization failed", err = error
      mix_messages_error.inc(labelValues = ["Exit", "INVALID_SPHINX"])
      return

    let (surbs, message) = extractSURBs(deserialized.message).valueOr:
      error "Extracting surbs from payload failed", err = error
      mix_messages_error.inc(labelValues = ["Exit", "INVALID_MSG_SURBS"])
      return

    if processedSP.destination == Hop():
      error "no destination available"
      mix_messages_error.inc(labelValues = ["Exit", "NO_DESTINATION"])
      return

    let destBytes = processedSP.destination.get()

    let (destPeerId, destAddr) = bytesToMultiAddr(destBytes).valueOr:
      error "Failed to convert bytes to multiaddress", err = error
      mix_messages_error.inc(labelValues = ["Exit", "INVALID_DEST"])
      return

    trace "Exit node - Received mix message",
      peerId,
      message = deserialized.message,
      codec = deserialized.codec,
      to = destPeerId

    await mixProto.exitLayer.onMessage(
      deserialized.codec, message, destAddr, destPeerId, surbs
    )

    mix_messages_forwarded.inc(labelValues = ["Exit"])
  of Reply:
    trace "# Reply", id = processedSP.id

    if not mixProto.connCreds.hasKey(processedSP.id):
      mix_messages_error.inc(labelValues = ["Sender/Reply", "NO_CONN_FOUND"])
      return

    var connCred: ConnCreds
    try:
      connCred = mixProto.connCreds[processedSP.id]
    except KeyError:
      doAssert false, "checked with hasKey"

    let reply = processReply(
      connCred.surbKey, connCred.surbSecret, processedSP.delta_prime
    ).valueOr:
      error "could not process reply", id = processedSP.id
      mix_messages_error.inc(labelValues = ["Reply", "INVALID_CREDS"])
      return

    # Deleting all other SURBs associated to this
    for id in connCred.igroup.members:
      mixProto.connCreds.del(id)

    let msgChunk = MessageChunk.deserialize(reply).valueOr:
      error "Deserialization failed", err = error
      mix_messages_error.inc(labelValues = ["Reply", "INVALID_SPHINX"])
      return

    let unpaddedMsg = msgChunk.removePadding().valueOr:
      error "Unpadding message failed", err = error
      mix_messages_error.inc(labelValues = ["Reply", "INVALID_SPHINX"])
      return

    let deserialized = MixMessage.deserialize(unpaddedMsg).valueOr:
      error "Deserialization failed", err = error
      mix_messages_error.inc(labelValues = ["Reply", "INVALID_SPHINX"])
      return

    await connCred.incoming.put(deserialized.message)
  of Intermediate:
    trace "# Intermediate: ", peerId, multiAddr
    # Add delay
    mix_messages_recvd.inc(labelValues = ["Intermediate"])
    await sleepAsync(milliseconds(processedSP.delayMs))

    # Forward to next hop
    let nextHopBytes = processedSP.nextHop.get()

    let (nextPeerId, nextAddr) = bytesToMultiAddr(nextHopBytes).valueOr:
      error "Failed to convert bytes to multiaddress", err = error
      mix_messages_error.inc(labelValues = ["Intermediate", "INVALID_DEST"])
      return

    try:
      let nextHopConn =
        await mixProto.switch.dial(nextPeerId, @[nextAddr], MixProtocolID)
      defer:
        await nextHopConn.close()

      await nextHopConn.writeLp(processedSP.serializedSphinxPacket)
      mix_messages_forwarded.inc(labelValues = ["Intermediate"])
    except CancelledError as exc:
      raise exc
    except DialFailedError as exc:
      error "Failed to dial next hop: ", err = exc.msg
      mix_messages_error.inc(labelValues = ["Intermediate", "DIAL_FAILED"])
    except LPStreamError as exc:
      error "Failed to write to next hop: ", err = exc.msg
      mix_messages_error.inc(labelValues = ["Intermediate", "DIAL_FAILED"])
  of Duplicate:
    mix_messages_error.inc(labelValues = ["Intermediate/Exit", "DUPLICATE"])
  of InvalidMAC:
    mix_messages_error.inc(labelValues = ["Intermediate/Exit", "INVALID_MAC"])

proc getMaxMessageSizeForCodec*(
    codec: string, numberOfSurbs: uint8 = 0
): Result[int, string] =
  ## Computes the maximum payload size (in bytes) available for a message when encoded  
  ## with the given `codec`, optionally including space for the chosen number of surbs.  
  ## Returns an error if the codec + surb overhead exceeds the data capacity.  
  let serializedMsg = MixMessage.init(@[], codec).serialize()
  let totalLen = serializedMsg.len + SurbLenSize + (int(numberOfSurbs) * SurbSize)
  if totalLen > DataSize:
    return err("cannot encode messages for this codec")
  return ok(DataSize - totalLen)

proc buildSurb(
    mixProto: MixProtocol, id: SURBIdentifier, destPeerId: PeerId, exitPeerId: PeerId
): Result[SURB, string] =
  var
    multiAddrs: seq[MultiAddress] = @[]
    publicKeys: seq[FieldElement] = @[]
    hops: seq[Hop] = @[]
    delay: seq[seq[byte]] = @[]

  if mixProto.pubNodeInfo.len < PathLength:
    return err("No. of public mix nodes less than path length")

  # Remove exit and dest node from nodes to consider for surbs
  var pubNodeInfoKeys =
    mixProto.pubNodeInfo.keys.toSeq().filterIt(it != exitPeerId and it != destPeerId)
  var availableIndices = toSeq(0 ..< pubNodeInfoKeys.len)

  # Select L mix nodes at random
  for i in 0 ..< PathLength:
    let (peerId, multiAddr, mixPubKey, delayMillisec) =
      if i < PathLength - 1:
        let randomIndexPosition = cryptoRandomInt(mixProto.rng, availableIndices.len).valueOr:
          return err("failed to generate random num: " & error)
        let selectedIndex = availableIndices[randomIndexPosition]
        let randPeerId = pubNodeInfoKeys[selectedIndex]
        availableIndices.del(randomIndexPosition)
        debug "Selected mix node for surbs: ", indexInPath = i, peerId = randPeerId
        let mixPubInfo = mixProto.pubNodeInfo.getOrDefault(randPeerId)
        # Compute delay
        let delayMillisec = cryptoRandomInt(mixProto.rng, 3).valueOr:
          mix_messages_error.inc(labelValues = ["Entry/SURB", "NON_RECOVERABLE"])
          return err("failed to generate random number: " & error)
        (mixPubInfo.peerId, mixPubInfo.multiAddr, mixPubInfo.mixPubKey, delayMillisec)
      else:
        (
          mixProto.mixNodeInfo.peerId, mixProto.mixNodeInfo.multiAddr,
          mixProto.mixNodeInfo.mixPubKey, 0,
        ) # No delay

    publicKeys.add(mixPubKey)

    let multiAddrBytes = multiAddrToBytes(peerId, multiAddr).valueOr:
      mix_messages_error.inc(labelValues = ["Entry/SURB", "INVALID_MIX_INFO"])
      return err("failed to convert multiaddress to bytes: " & error)

    hops.add(Hop.init(multiAddrBytes))

    delay.add(@(delayMillisec.uint16.toBytesBE()))

  return createSURB(publicKeys, delay, hops, id)

proc buildSurbs(
    mixProto: MixProtocol,
    incoming: AsyncQueue[seq[byte]],
    numSurbs: uint8,
    destPeerId: PeerId,
    exitPeerId: PeerId,
): Result[seq[SURB], string] =
  var response: seq[SURB]
  var igroup = SURBIdentifierGroup(members: initHashSet[SURBIdentifier]())

  for _ in 0.uint8 ..< numSurbs:
    var id: SURBIdentifier
    hmacDrbgGenerate(mixProto.rng[], id)
    let surb = ?mixProto.buildSurb(id, destPeerId, exitPeerId)
    igroup.members.incl(id)
    mixProto.connCreds[id] = ConnCreds(
      igroup: igroup,
      surbSecret: surb.secret.get(),
      surbKey: surb.key,
      incoming: incoming,
    )
    response.add(surb)

  return ok(response)

proc prepareMsgWithSurbs(
    mixProto: MixProtocol,
    incoming: AsyncQueue[seq[byte]],
    msg: seq[byte],
    numSurbs: uint8 = 0,
    destPeerId: PeerId,
    exitPeerId: PeerId,
): Result[seq[byte], string] =
  let surbs = mixProto.buildSurbs(incoming, numSurbs, destPeerId, exitPeerId).valueOr:
    return err(error)
  serializeMessageWithSURBs(msg, surbs)

type SendPacketLogType* = enum
  Entry
  Reply

type SendPacketLogConfig = object # TODO:benchmark params go here
  logType: SendPacketLogType

proc sendPacket(
    mixProto: MixProtocol,
    peerId: PeerId,
    multiAddress: MultiAddress,
    sphinxPacket: SphinxPacket,
    logConfig: SendPacketLogConfig,
) {.async: (raises: [CancelledError]).} =
  ## Send the wrapped message to the first mix node in the selected path

  let label = $logConfig.logType
  try:
    let nextHopConn =
      await mixProto.switch.dial(peerId, @[multiAddress], @[MixProtocolID])
    defer:
      await nextHopConn.close()
    await nextHopConn.writeLp(sphinxPacket.serialize())
  except DialFailedError as exc:
    error "Failed to dial next hop: ",
      peerId = peerId, address = multiAddress, err = exc.msg
    mix_messages_error.inc(labelValues = [label, "SEND_FAILED"])
  except LPStreamError as exc:
    error "Failed to write to next hop: ",
      peerId = peerId, address = multiAddress, err = exc.msg
    mix_messages_error.inc(labelValues = [label, "SEND_FAILED"])
  except CancelledError as exc:
    raise exc

  mix_messages_forwarded.inc(labelValues = ["Entry"])

proc buildMessage(
    msg: seq[byte], codec: string, peerId: PeerId
): Result[Message, (string, string)] =
  let
    mixMsg = MixMessage.init(msg, codec)
    serialized = mixMsg.serialize()

  if serialized.len > DataSize:
    return err(("message size exceeds maximum payload size", "INVALID_SIZE"))

  let
    paddedMsg = addPadding(serialized, peerId)
    serializedMsgChunk = paddedMsg.serialize()

  ok(serializedMsgChunk)

## Represents the final target of a mixnet message.  
## contains the peer id and multiaddress of the destination node.  
type MixDestination* = object
  peerId: PeerId
  address: MultiAddress

proc init*(T: typedesc[MixDestination], peerId: PeerId, address: MultiAddress): T =
  ## Initializes a destination object with the given peer id and multiaddress.  
  T(peerId: peerId, address: address)

proc `$`*(d: MixDestination): string =
  $d.address & "/p2p/" & $d.peerId

proc anonymizeLocalProtocolSend*(
    mixProto: MixProtocol,
    incoming: AsyncQueue[seq[byte]],
    msg: seq[byte],
    codec: string,
    destination: MixDestination,
    numSurbs: uint8,
) {.async: (raises: [CancelledError, LPStreamError]).} =
  mix_messages_recvd.inc(labelValues = ["Entry"])

  let logConfig = SendPacketLogConfig(logType: Entry)

  var
    publicKeys: seq[FieldElement] = @[]
    hop: seq[Hop] = @[]
    delay: seq[seq[byte]] = @[]
    exitPeerId: PeerId

  # Select L mix nodes at random
  let numMixNodes = mixProto.pubNodeInfo.len
  var numAvailableNodes = numMixNodes

  debug "Destination data", destination

  if mixProto.pubNodeInfo.hasKey(destination.peerId):
    numAvailableNodes = numMixNodes - 1

  if numAvailableNodes < PathLength:
    error "No. of public mix nodes less than path length.",
      numMixNodes = numAvailableNodes, pathLength = PathLength
    mix_messages_error.inc(labelValues = ["Entry", "LOW_MIX_POOL"])
    return

  # Skip the destination peer
  var pubNodeInfoKeys =
    mixProto.pubNodeInfo.keys.toSeq().filterIt(it != destination.peerId)
  var availableIndices = toSeq(0 ..< pubNodeInfoKeys.len)

  var i = 0
  var nextHopAddr: MultiAddress
  var nextHopPeerId: PeerId
  while i < PathLength:
    let randomIndexPosition = cryptoRandomInt(mixProto.rng, availableIndices.len).valueOr:
      error "Failed to generate random number", err = error
      mix_messages_error.inc(labelValues = ["Entry", "NON_RECOVERABLE"])
      return
    let selectedIndex = availableIndices[randomIndexPosition]
    let randPeerId = pubNodeInfoKeys[selectedIndex]
    availableIndices.del(randomIndexPosition)

    # Last hop will be the exit node that will forward the request
    if i == PathLength - 1:
      exitPeerId = randPeerId

    debug "Selected mix node: ", indexInPath = i, peerId = randPeerId

    # Extract multiaddress, mix public key, and hop
    let (peerId, multiAddr, mixPubKey, _) =
      mixProto.pubNodeInfo.getOrDefault(randPeerId).get()

    publicKeys.add(mixPubKey)

    if i == 0:
      nextHopAddr = multiAddr
      nextHopPeerId = peerId

    let multiAddrBytes = multiAddrToBytes(peerId, multiAddr).valueOr:
      error "Failed to convert multiaddress to bytes", err = error
      mix_messages_error.inc(labelValues = ["Entry", "INVALID_MIX_INFO"])
      #TODO: should we skip and pick a different node here??
      return

    hop.add(Hop.init(multiAddrBytes))

    # Compute delay
    let delayMillisec =
      if i != PathLength - 1:
        cryptoRandomInt(mixProto.rng, 3).valueOr:
          error "Failed to generate random number", err = error
          mix_messages_error.inc(labelValues = ["Entry", "NON_RECOVERABLE"])
          return
      else:
        0 # Last hop does not require a delay

    delay.add(@(delayMillisec.uint16.toBytesBE()))

    i = i + 1

  # Encode destination
  let destAddrBytes = multiAddrToBytes(destination.peerId, destination.address).valueOr:
    error "Failed to convert multiaddress to bytes", err = error
    mix_messages_error.inc(labelValues = ["Entry", "INVALID_DEST"])
    return
  let destHop = Hop.init(destAddrBytes)

  let msgWithSurbs = mixProto.prepareMsgWithSurbs(
    incoming, msg, numSurbs, destination.peerId, exitPeerId
  ).valueOr:
    error "Could not prepend SURBs", err = error
    return

  let message = buildMessage(msgWithSurbs, codec, mixProto.mixNodeInfo.peerId).valueOr:
    error "Error building message", err = error[0]
    mix_messages_error.inc(labelValues = ["Entry", error[1]])
    return

  # Wrap in Sphinx packet
  let sphinxPacket = wrapInSphinxPacket(message, publicKeys, delay, hop, destHop).valueOr:
    error "Failed to wrap in sphinx packet", err = error
    mix_messages_error.inc(labelValues = ["Entry", "NON_RECOVERABLE"])
    return

  # Send the wrapped message to the first mix node in the selected path
  await mixProto.sendPacket(nextHopPeerId, nextHopAddr, sphinxPacket, logConfig)

proc reply(
    mixProto: MixProtocol, surb: SURB, msg: seq[byte]
) {.async: (raises: [CancelledError]).} =
  let (peerId, multiAddr) = surb.hop.get().bytesToMultiAddr().valueOr:
      error "could not obtain multiaddress from hop", err = error
      return

  # Message does not require a codec, as it is already associated to a specific I
  let message = buildMessage(msg, "", peerId).valueOr:
    error "could not build reply message", err = error
    return

  let sphinxPacket = useSURB(surb, message)

  await mixProto.sendPacket(
    peerId, multiAddr, sphinxPacket, SendPacketLogConfig(logType: Reply)
  )

proc init*(
    mixProto: MixProtocol,
    mixNodeInfo: MixNodeInfo,
    pubNodeInfo: Table[PeerId, MixPubInfo],
    switch: Switch,
    tagManager: TagManager = TagManager.new(),
    rng: ref HmacDrbgContext = newRng(),
) =
  mixProto.mixNodeInfo = mixNodeInfo
  mixProto.pubNodeInfo = pubNodeInfo
  mixProto.switch = switch
  mixProto.tagManager = tagManager
  mixProto.destReadBehavior = newTable[string, destReadBehaviorCb]()

  let onReplyDialer = proc(
      surb: SURB, message: seq[byte]
  ) {.async: (raises: [CancelledError]).} =
    await mixProto.reply(surb, message)

  mixProto.exitLayer = ExitLayer.init(switch, onReplyDialer, mixProto.destReadBehavior)
  mixProto.codecs = @[MixProtocolID]
  mixProto.rng = rng
  mixProto.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      await mixProto.handleMixNodeConnection(conn)
    except LPStreamError as e:
      debug "Stream error", conn = conn, err = e.msg

proc new*(
    T: typedesc[MixProtocol],
    mixNodeInfo: MixNodeInfo,
    pubNodeInfo: Table[PeerId, MixPubInfo],
    switch: Switch,
    tagManager: TagManager = TagManager.new(),
    rng: ref HmacDrbgContext = newRng(),
): T =
  let mixProto = new(T)
  mixProto.init(mixNodeInfo, pubNodeInfo, switch)
  mixProto

proc new*(
    T: typedesc[MixProtocol],
    index, numNodes: int,
    switch: Switch,
    nodeFolderInfoPath: string = ".",
    rng: ref HmacDrbgContext = newRng(),
): Result[T, string] =
  ## Constructs a new `MixProtocol` instance for the mix node at `index`,  
  ## loading its private info from `nodeInfo` and the public info of all other nodes from `pubInfo`.  
  let mixNodeInfo = MixNodeInfo.readFromFile(index, nodeFolderInfoPath / fmt"nodeInfo").valueOr:
    return err("Failed to load mix node info for index " & $index & " - err: " & error)

  let pubNodeInfo = loadAllButIndexMixPubInfo(
    index, numNodes, nodeFolderInfoPath / fmt"pubInfo"
  ).valueOr:
    return err("Failed to load mix pub info for index " & $index & " - err: " & error)

  let mixProto =
    MixProtocol.new(mixNodeInfo, pubNodeInfo, switch, TagManager.new(), rng)

  return ok(mixProto)

proc setNodePool*(
    mixProtocol: MixProtocol, mixNodeTable: Table[PeerId, MixPubInfo]
) {.gcsafe, raises: [].} =
  mixProtocol.pubNodeInfo = mixNodeTable

proc getNodePoolSize*(mixProtocol: MixProtocol): int {.gcsafe, raises: [].} =
  mixProtocol.pubNodeInfo.len
