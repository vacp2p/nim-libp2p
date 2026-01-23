# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import chronos
import secure, ../../stream/connection

const PlainTextCodec* = "/plaintext/1.0.0"

type PlainText* = ref object of Secure

method init(p: PlainText) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    ## plain text doesn't do anything
    discard

  p.codec = PlainTextCodec
  p.handler = handle

proc new*(T: typedesc[PlainText]): T =
  let plainText = T()
  plainText.init()
  plainText
