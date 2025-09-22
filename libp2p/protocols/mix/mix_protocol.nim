import chronicles, chronos, sequtils, strutils, os, results
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
      deserialized.codec, deserialized.message, destAddr, destPeerId
    )

    mix_messages_forwarded.inc(labelValues = ["Exit"])
  of Reply:
    # TODO: implement
    discard
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
  ## with the given `codec` 
  ## Returns an error if the codec length would cause it to exceeds the data capacity.  
  let serializedMsg = MixMessage.init(@[], codec).serialize()
  if serializedMsg.len > DataSize:
    return err("cannot encode messages for this codec")
  return ok(DataSize - serializedMsg.len)

proc sendPacket(
    mixProto: MixProtocol,
    multiAddrs: MultiAddress,
    sphinxPacket: seq[byte],
    label: string,
) {.async: (raises: [CancelledError]).} =
  ## Send the wrapped message to the first mix node in the selected path

  let (firstMixPeerId, firstMixAddr) = parseFullAddress(multiAddrs).valueOr:
    error "Invalid multiaddress", err = error
    mix_messages_error.inc(labelValues = [label, "NON_RECOVERABLE"])
    return

  try:
    let nextHopConn =
      await mixProto.switch.dial(firstMixPeerId, @[firstMixAddr], @[MixProtocolID])
    defer:
      await nextHopConn.close()
    await nextHopConn.writeLp(sphinxPacket)
  except DialFailedError as exc:
    error "Failed to dial next hop: ",
      peerId = firstMixPeerId, address = firstMixAddr, err = exc.msg
    mix_messages_error.inc(labelValues = [label, "SEND_FAILED"])
  except LPStreamError as exc:
    error "Failed to write to next hop: ",
      peerId = firstMixPeerId, address = firstMixAddr, err = exc.msg
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

  var
    multiAddrs: seq[MultiAddress] = @[]
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
    multiAddrs.add(multiAddr)
    publicKeys.add(mixPubKey)

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

  #Encode destination
  let destAddrBytes = multiAddrToBytes(destination.peerId, destination.address).valueOr:
    error "Failed to convert multiaddress to bytes", err = error
    mix_messages_error.inc(labelValues = ["Entry", "INVALID_DEST"])
    return
  let destHop = Hop.init(destAddrBytes)
  let message = buildMessage(msg, codec, mixProto.mixNodeInfo.peerId).valueOr:
    error "Error building message", err = error[0]
    mix_messages_error.inc(labelValues = ["Entry", error[1]])
    return

  # Wrap in Sphinx packet
  let sphinxPacket = wrapInSphinxPacket(message, publicKeys, delay, hop, destHop).valueOr:
    error "Failed to wrap in sphinx packet", err = error
    mix_messages_error.inc(labelValues = ["Entry", "NON_RECOVERABLE"])
    return

  # Send the wrapped message to the first mix node in the selected path
  await mixProto.sendPacket(multiAddrs[0], sphinxPacket, "Entry")

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

  mixProto.exitLayer = ExitLayer.init(switch)
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
