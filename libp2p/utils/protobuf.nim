# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/macros, results, protobuf_serialization

when defined(libp2p_protobuf_metrics):
  import ./protobuf_metrics

template trackEncodeBytes*(count: int64, typeName: string, domain: string) =
  when defined(libp2p_protobuf_metrics):
    libp2p_protobuf_bytes_write.inc(count, labelValues = [domain & "." & typeName])

template trackDecodeBytes*(count: int64, typeName: string, domain: string) =
  when defined(libp2p_protobuf_metrics):
    libp2p_protobuf_bytes_read.inc(count, labelValues = [domain & "." & typeName])

macro decodeFor*(
    _: type Protobuf, Types: untyped, withMetrics: bool = false, domain: string = ""
): untyped =
  ## This generates decode protobuf procs for `Types`
  let doMetrics = newLit(withMetrics.eqIdent("true"))
  var stmts = newStmtList()
  for T in Types:
    let decodeName = ident("decode" & $T)
    let metricLabel = newLit(domain.strVal & "." & $T)
    stmts.add quote do:
      proc `decodeName`(buf2: seq[byte]): `T` {.raises: [SerializationError].} =
        when defined(libp2p_protobuf_metrics) and `doMetrics`:
          libp2p_protobuf_bytes_read.inc(buf2.len.int64, labelValues = [`metricLabel`])

        decode(Protobuf, buf2, `T`)

      proc decode*(_: type `T`, buf: seq[byte]): Result[`T`, string] =
        try:
          ok(`decodeName`(buf))
        except SerializationError as e:
          err("failed to decode " & $(`T`) & " from protobuf bytes. " & e.msg)

  stmts

macro serializerFor*(
    _: type Protobuf, Types: untyped, withMetrics: bool = false, domain: string = ""
): untyped =
  ## This generates encode/decode protobuf procs for `Types`
  let doMetrics = newLit(withMetrics.eqIdent("true"))
  var stmts = newStmtList()
  for T in Types:
    let decodeName = ident("decode" & $T)
    let metricLabel = newLit(domain.strVal & "." & $T)
    stmts.add quote do:
      proc encode*(c: `T`): seq[byte] =
        let buf = encode(Protobuf, c)
        when defined(libp2p_protobuf_metrics) and `doMetrics`:
          libp2p_protobuf_bytes_write.inc(buf.len.int64, labelValues = [`metricLabel`])
        buf

      proc `decodeName`(buf2: seq[byte]): `T` {.raises: [SerializationError].} =
        when defined(libp2p_protobuf_metrics) and `doMetrics`:
          libp2p_protobuf_bytes_read.inc(buf2.len.int64, labelValues = [`metricLabel`])

        decode(Protobuf, buf2, `T`)

      proc decode*(_: type `T`, buf: seq[byte]): Result[`T`, string] =
        try:
          ok(`decodeName`(buf))
        except SerializationError as e:
          err("failed to decode " & $(`T`) & " from protobuf bytes. " & e.msg)

  stmts
