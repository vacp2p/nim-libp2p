# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronicles
import json_serialization
import ../../../libp2p/utils/redact
import ../../tools/unittest

# --- module-private (exported = false) type ---------------------------------
# Mirrors the `noise.nim` pattern: the generated `$` / `writeValue` overloads
# are intentionally *not* exported, so they are only reachable within this
# module. Exercise them through module-local inspection helpers.
type PrivateSessionKey = object
  raw*: array[32, byte]

redactType(PrivateSessionKey, exported = false)

proc privateDollar(k: PrivateSessionKey): string =
  $k

proc privateChronicles(k: PrivateSessionKey): string =
  chroniclesFormatItIMPL(k)

proc privateJson(k: PrivateSessionKey): string =
  Json.encode(k)

# --- default-exported composite type -----------------------------------------
type CompositeSecret = object
  tag: int
  raw: seq[byte]
  nested: PrivateSessionKey

redactType(CompositeSecret)

const
  marker = Redacted
  jsonMarker = Json.encode(Redacted)

suite "redactType macro":
  test "default-exported composite type is redacted via `$`, Chronicles, Json":
    let nested = PrivateSessionKey(
      raw: [
        byte 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
        22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
      ]
    )
    let comp = CompositeSecret(tag: 7, raw: @[byte 0xDE, 0xAD], nested: nested)

    check:
      $comp == marker
      chroniclesFormatItIMPL(comp) == marker
      Json.encode(comp) == jsonMarker

  test "module-private (exported = false) type is redacted via all sinks":
    var k = PrivateSessionKey()
    for i in 0 ..< k.raw.len:
      k.raw[i] = byte(i mod 256)

    check:
      privateDollar(k) == marker
      privateChronicles(k) == marker
      privateJson(k) == jsonMarker
