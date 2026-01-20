import std/[options]
import ../../../[peerid]
import ./[extensions_types]

type
  PartialMessageExtensionConfig* = object

  PartialMessageExtension* = ref object of Extension
    config: PartialMessageExtensionConfig

proc new*(
    T: typedesc[PartialMessageExtension], config: PartialMessageExtensionConfig
): Extension =
  PartialMessageExtension(config: config)

proc new*(
    T: typedesc[PartialMessageExtension], config: Option[PartialMessageExtensionConfig]
): Option[Extension] =
  if config.isNone():
    return none(Extension)
  some(PartialMessageExtension.new(config.get()))

method onNegotiated*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard

method onHandleRPC*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard
