# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## `protobuf_serialization` support for types declared as `distinct seq[byte]`.

import std/macros
import protobuf_serialization

macro distinctByteSeqSerialization*(T: typedesc): untyped =
  ## Generates the `pbytes` protobuf extension for `T`.
  ##
  ## `T` must be a `distinct seq[byte]` type. Its wire representation is the
  ## underlying byte sequence, and empty sequences use protobuf's default
  ## sequence handling.
  result = quote:
    Protobuf.extensionDefaults(`T`, pbytes, defaultSeq = true)

    func computeFieldSize*(
        field: int, value: `T`, ProtoType: type ProtobufExt, skipDefault: static bool
    ): int =
      computeFieldSize(field, seq[byte](value), pbytes, skipDefault)

    proc writeField*(
        stream: OutputStream,
        field: int,
        value: `T`,
        ProtoType: type ProtobufExt,
        skipDefault: static bool = false,
    ) {.raises: [IOError].} =
      writeField(stream, field, seq[byte](value), pbytes, skipDefault)

    proc readFieldInto*(
        stream: InputStream,
        value: var `T`,
        header: FieldHeader,
        ProtoType: type ProtobufExt,
    ): bool {.raises: [SerializationError, IOError].} =
      var bytes: seq[byte]
      if readFieldInto(stream, bytes, header, pbytes):
        value = `T`(bytes)
        true
      else:
        false
