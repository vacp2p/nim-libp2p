# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/macros, results, protobuf_serialization

macro serializerFor*(_: type Protobuf, Types: untyped): untyped =
  ## This generates encode/decode protobuf procs for `Types`
  var stmts = newStmtList()
  for T in Types:
    let decodeName = ident("decode" & $T)
    stmts.add quote do:
      proc encode*(c: `T`): seq[byte] =
        encode(Protobuf, c)

      proc `decodeName`(buf2: seq[byte]): `T` {.raises: [SerializationError].} =
        decode(Protobuf, buf2, `T`)

      proc decode*(_: type `T`, buf: seq[byte]): Opt[`T`] =
        try:
          Opt.some(`decodeName`(buf))
        except SerializationError:
          Opt.none(`T`)

  stmts
