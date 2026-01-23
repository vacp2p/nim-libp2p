# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

## This module implements transcoder interface.
import vbuffer

type Transcoder* = object
  stringToBuffer*:
    proc(s: string, vb: var VBuffer): bool {.nimcall, gcsafe, noSideEffect, raises: [].}
  bufferToString*: proc(vb: var VBuffer, s: var string): bool {.
    nimcall, gcsafe, noSideEffect, raises: []
  .}
  validateBuffer*:
    proc(vb: var VBuffer): bool {.nimcall, gcsafe, noSideEffect, raises: [].}
