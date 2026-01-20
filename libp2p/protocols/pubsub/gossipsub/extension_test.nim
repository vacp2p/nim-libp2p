import std/[options]
import ../../../[peerid]
import ./[extensions_types]

type
  TestExtensionConfig* = object
    onNegotiated*: PeerCallback = noopPeerCallback
    onHandleRPC*: PeerCallback = noopPeerCallback

  TestExtension* = ref object of Extension
    config: TestExtensionConfig

proc new*(T: typedesc[TestExtension], config: TestExtensionConfig): Extension =
  TestExtension(config: config)

proc new*(
    T: typedesc[TestExtension], config: Option[TestExtensionConfig]
): Option[Extension] =
  if config.isNone():
    return none(Extension)
  some(TestExtension.new(config.get()))

method onNegotiated*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.config.onNegotiated(peerId)

method onHandleRPC*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.config.onHandleRPC(peerId)
