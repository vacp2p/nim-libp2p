import chronicles, chronos, sequtils, os, results, sets
import std/[strformat, tables], metrics
import
  ./[
    curve25519, fragmentation, mix_message, mix_node, sphinx, serialization,
    tag_manager, mix_metrics, exit_layer, multiaddr, exit_connection,
  ]
import stew/endians2
import ../protocol
import ../../utils/sequninit
import ../../stream/[connection, lpstream]
import ../../[switch, multicodec, peerinfo]

when defined(enable_mix_benchmarks):
  import ./benchmark
  from times import getTime, toUnixFloat, `-`, initTime, `$`, inMilliseconds, Time

when defined(libp2p_mix_experimental_exit_is_dest):
  {.warning: "experimental support for mix exit == destination is enabled!".}

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
  when defined(enable_mix_benchmarks):
    let metadataBytes = newSeqUninit[byte](MetadataSize)
    await conn.readExactly(addr metadataBytes[0], MetadataSize)

  let receivedBytes =
    try:
      await conn.readLp(PacketSize)
    except CancelledError as exc:
      raise exc
    finally:
      await conn.close()

  when defined(enable_mix_benchmarks):
    let startTime = getTime()

    if metadataBytes.len == 0:
      mix_messages_error.inc(labelValues = ["Intermediate/Exit", "NO_DATA"])
      return # No data, end of stream  

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

  when defined(enable_mix_benchmarks):
    let metadata = Metadata.deserialize(metadataBytes)

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

    trace "Exit node - Received mix message",
      peerId, message = deserialized.message, codec = deserialized.codec

    when defined(enable_mix_benchmarks):
      benchmarkLog "Exit",
        mixProto.switch.peerInfo.peerId,
        startTime,
        metadata,
        Opt.some(conn.peerId),
        Opt.none(PeerId)

    await mixProto.exitLayer.onMessage(
      deserialized.codec, message, processedSP.destination, surbs
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

    when defined(enable_mix_benchmarks):
      benchmarkLog "Reply",
        mixProto.switch.peerInfo.peerId,
        startTime,
        metadata,
        Opt.some(conn.peerId),
        Opt.none(PeerId)

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

    when defined(enable_mix_benchmarks):
      benchmarkLog "Intermediate",
        mixProto.switch.peerInfo.peerId,
        startTime,
        metadata,
        Opt.some(conn.peerId),
        Opt.some(peerId)

    try:
      let nextHopConn =
        await mixProto.switch.dial(nextPeerId, @[nextAddr], MixProtocolID)
      defer:
        await nextHopConn.close()

      when defined(enable_mix_benchmarks):
        await nextHopConn.write(metadataBytes)

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

type SendPacketLogConfig = object
  logType: SendPacketLogType
  when defined(enable_mix_benchmarks):
    startTime: Time
    metadata: Metadata

proc sendPacket(
    mixProto: MixProtocol,
    peerId: PeerId,
    multiAddress: MultiAddress,
    sphinxPacket: SphinxPacket,
    logConfig: SendPacketLogConfig,
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Send the wrapped message to the first mix node in the selected path

  let label = $logConfig.logType

  when defined(enable_mix_benchmarks):
    if logConfig.logType == Entry:
      benchmarkLog "Sender",
        mixProto.switch.peerInfo.peerId,
        logConfig.startTime,
        logConfig.metadata,
        Opt.none(PeerId),
        Opt.some(peerId)

  try:
    let nextHopConn =
      await mixProto.switch.dial(peerId, @[multiAddress], @[MixProtocolID])
    defer:
      await nextHopConn.close()

    when defined(enable_mix_benchmarks):
      await nextHopConn.writeLp(logConfig.metadata.serialize())

    await nextHopConn.writeLp(sphinxPacket.serialize())
  except DialFailedError as exc:
    mix_messages_error.inc(labelValues = [label, "SEND_FAILED"])
    return err(fmt"Failed to dial to next hop ({peerId}, {multiAddress}): {exc.msg}")
  except LPStreamError as exc:
    mix_messages_error.inc(labelValues = [label, "SEND_FAILED"])
    return err(fmt"Failed to write to next hop ({peerId}, {multiAddress}): {exc.msg}")
  except CancelledError as exc:
    raise exc

  mix_messages_forwarded.inc(labelValues = ["Entry"])
  return ok()

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

type DestinationType* = enum
  ForwardAddr
  MixNode

## Represents the final target of a mixnet message.  
## contains the peer id and multiaddress of the destination node
## if the exit != destination  
type MixDestination* = object
  peerId: PeerId
  case kind: DestinationType
  of ForwardAddr:
    address: MultiAddress
  else:
    discard

proc `$`*(d: MixDestination): string =
  case d.kind
  of ForwardAddr:
    return "MixDestination[ForwardAddr](" & $d.address & "/p2p/" & $d.peerId & ")"
  of MixNode:
    return "MixDestination[MixNode](" & $d.peerId & ")"

when defined(libp2p_mix_experimental_exit_is_dest):
  proc exitNode*(T: typedesc[MixDestination], p: PeerId): T =
    T(kind: DestinationType.MixNode, peerId: p)

proc forwardToAddr*(T: typedesc[MixDestination], p: PeerId, address: MultiAddress): T =
  T(kind: DestinationType.ForwardAddr, peerId: p, address: address)

proc init*(T: typedesc[MixDestination], p: PeerId, address: MultiAddress): T =
  MixDestination.forwardToAddr(p, address)

proc anonymizeLocalProtocolSend*(
    mixProto: MixProtocol,
    incoming: AsyncQueue[seq[byte]],
    msg: seq[byte],
    codec: string,
    destination: MixDestination,
    numSurbs: uint8,
): Future[Result[void, string]] {.async: (raises: [CancelledError, LPStreamError]).} =
  when not defined(libp2p_mix_experimental_exit_is_dest):
    doAssert destination.kind == ForwardAddr, "Only exit != destination is allowed"

  mix_messages_recvd.inc(labelValues = ["Entry"])

  var logConfig = SendPacketLogConfig(logType: Entry)
  when defined(enable_mix_benchmarks):
    # Assumes a fixed message layout whose first 16 bytes are the time at 
    # origin and msgId
    logConfig.startTime = getTime()
    logConfig.metadata = Metadata.deserialize(msg)

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
    mix_messages_error.inc(labelValues = ["Entry", "LOW_MIX_POOL"])
    return err(
      fmt"No. of public mix nodes ({numAvailableNodes}) less than path length ({PathLength})."
    )

  # Skip the destination peer
  var pubNodeInfoKeys = mixProto.pubNodeInfo.keys.toSeq()
  var availableIndices = toSeq(0 ..< pubNodeInfoKeys.len)

  let index = pubNodeInfoKeys.find(destination.peerId)
  if index != -1:
    availableIndices.del(index)
  elif destination.kind == MixNode:
    return err("Destination does not support mix")

  var nextHopAddr: MultiAddress
  var nextHopPeerId: PeerId
  for i in 0 ..< PathLength:
    let randomIndexPosition = cryptoRandomInt(mixProto.rng, availableIndices.len).valueOr:
      mix_messages_error.inc(labelValues = ["Entry", "NON_RECOVERABLE"])
      return err(fmt"Failed to generate random number: {error}")
    let selectedIndex = availableIndices[randomIndexPosition]
    var randPeerId = pubNodeInfoKeys[selectedIndex]
    availableIndices.del(randomIndexPosition)

    if destination.kind == ForwardAddr and randPeerId == destination.peerId:
      # Skip the destination peer
      continue

    # Last hop will be the exit node that will forward the request
    if i == PathLength - 1:
      case destination.kind
      of ForwardAddr:
        # Last hop will be the exit node that will fwd the request
        exitPeerId = randPeerId
      of MixNode:
        # Exist node will be the destination
        exitPeerId = destination.peerId
        randPeerId = destination.peerId

    debug "Selected mix node: ", indexInPath = i, peerId = randPeerId

    # Extract multiaddress, mix public key, and hop
    let (peerId, multiAddr, mixPubKey, _) =
      mixProto.pubNodeInfo.getOrDefault(randPeerId).get()

    publicKeys.add(mixPubKey)

    if i == 0:
      nextHopAddr = multiAddr
      nextHopPeerId = peerId

    let multiAddrBytes = multiAddrToBytes(peerId, multiAddr).valueOr:
      mix_messages_error.inc(labelValues = ["Entry", "INVALID_MIX_INFO"])
      return err(fmt"Failed to convert multiaddress to bytes: {error}")
      #TODO: should we skip and pick a different node here??

    hop.add(Hop.init(multiAddrBytes))

    # Compute delay
    let delayMillisec =
      if i != PathLength - 1:
        cryptoRandomInt(mixProto.rng, 3).valueOr:
          mix_messages_error.inc(labelValues = ["Entry", "NON_RECOVERABLE"])
          return err(fmt"Failed to generate random number: {error}")
      else:
        0 # Last hop does not require a delay

    delay.add(@(delayMillisec.uint16.toBytesBE()))

  # Encode destination
  let destHop =
    if destination.kind == ForwardAddr:
      let destAddrBytes = multiAddrToBytes(destination.peerId, destination.address).valueOr:
        mix_messages_error.inc(labelValues = ["Entry", "INVALID_DEST"])
        return err(fmt"Failed to convert multiaddress to bytes: {error}")
      Hop.init(destAddrBytes)
    else:
      Hop()

  let msgWithSurbs = mixProto.prepareMsgWithSurbs(
    incoming, msg, numSurbs, destination.peerId, exitPeerId
  ).valueOr:
    return err(fmt"Could not prepend SURBs: {error}")

  let message = buildMessage(msgWithSurbs, codec, mixProto.mixNodeInfo.peerId).valueOr:
    mix_messages_error.inc(labelValues = ["Entry", error[1]])
    return err(fmt"Error building message: {error[0]}")

  # Wrap in Sphinx packet
  let sphinxPacket = wrapInSphinxPacket(message, publicKeys, delay, hop, destHop).valueOr:
    mix_messages_error.inc(labelValues = ["Entry", "NON_RECOVERABLE"])
    return err(fmt"Failed to wrap in sphinx packet: {error}")

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

  let sendRes = await mixProto.sendPacket(
    peerId, multiAddr, sphinxPacket, SendPacketLogConfig(logType: Reply)
  )
  if sendRes.isErr:
    error "could not send reply", peerId, multiAddr, err = sendRes.error

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
