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
export registerDestReadBehavior
export MixNodes
export initMixMultiAddrByIndex

proc readLp*(maxSize: int): destReadBehaviorCb =
  ## create callback to read length prefixed msg, with the length encoded as a varint
  return proc(
      conn: Connection
  ): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
    await conn.readLp(maxSize)

proc readExactly*(nBytes: int): destReadBehaviorCb =
  ## create callback that waits for `nbytes` to be available, then read
  ## them and return them
  return proc(
      conn: Connection
  ): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
    let buf = newSeqUninit[byte](nBytes)
    await conn.readExactly(addr buf[0], nBytes)
    return buf

when defined(libp2p_mix_experimental_exit_is_dest):
  export exitNode
  export forwardToAddr
