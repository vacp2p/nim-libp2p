import ./mix/[mix_protocol, mix_node, entry_connection, exit_layer]
import ../stream/connection
import chronos
import ../utils/sequninit

export toConnection
export MixProtocolID
export MixProtocol

export initializeMixNodes
export getMixPubInfoByIndex
export writeToFile
export get
export `new`
export init
export getMaxMessageSizeForCodec
export deleteNodeInfoFolder
export deletePubInfoFolder
export MixDestination
export MixParameters
export destReadBehaviorCb
export DestReadBehavior
export registerDestReadBehavior
export MixNodes
export initMixMultiAddrByIndex

proc readLp*(maxSize: int): DestReadBehavior =
  ## Create a read behavior that reads length-prefixed messages (varint-encoded length).
  ## The exit layer will automatically restore the length prefix for the reply.
  let callback = proc(
      conn: Connection
  ): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
    await conn.readLp(maxSize)

  DestReadBehavior(callback: callback, usesLengthPrefix: true)

proc readExactly*(nBytes: int): DestReadBehavior =
  ## Create a read behavior that reads exactly nBytes without any length prefix.
  ## The exit layer will not add a length prefix to the reply.
  let callback = proc(
      conn: Connection
  ): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
    let buf = newSeqUninit[byte](nBytes)
    await conn.readExactly(addr buf[0], nBytes)
    return buf

  DestReadBehavior(callback: callback, usesLengthPrefix: false)

when defined(libp2p_mix_experimental_exit_is_dest):
  export exitNode
  export forwardToAddr
