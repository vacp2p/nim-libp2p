# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
  config.withValue(c):
    some(PartialMessageExtension.new(c))
  else:
    none(Extension)

method onNegotiated*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard

method onHandleRPC*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard
