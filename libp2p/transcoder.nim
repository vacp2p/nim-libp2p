## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements transcoder interface.
import vbuffer

type
  Transcoder* = object
    stringToBuffer*: proc(s: string,
                          vb: var VBuffer): bool {.nimcall, gcsafe, noSideEffect, raises: [Defect].}
    bufferToString*: proc(vb: var VBuffer,
                          s: var string): bool {.nimcall, gcsafe, noSideEffect, raises: [Defect].}
    validateBuffer*: proc(vb: var VBuffer): bool {.nimcall, gcsafe, noSideEffect, raises: [Defect].}
