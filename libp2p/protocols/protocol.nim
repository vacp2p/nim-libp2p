# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos
import ../stream/connection

type
  LPProtoHandler* = proc (
    conn: Connection,
    proto: string):
    Future[void]
    {.gcsafe, raises: [Defect].}

  LPProtocol* = ref object of RootObj
    codecs*: seq[string]
    handler*: LPProtoHandler ## this handler gets invoked by the protocol negotiator
    started*: bool

method init*(p: LPProtocol) {.base, gcsafe.} = discard
method start*(p: LPProtocol) {.async, base.} = p.started = true
method stop*(p: LPProtocol) {.async, base.} = p.started = false


func codec*(p: LPProtocol): string =
  assert(p.codecs.len > 0, "Codecs sequence was empty!")
  p.codecs[0]

func `codec=`*(p: LPProtocol, codec: string) =
  # always insert as first codec
  # if we use this abstraction
  p.codecs.insert(codec, 0)
