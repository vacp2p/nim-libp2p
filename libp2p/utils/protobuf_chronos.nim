# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, protobuf_serialization, protobuf_serialization/extension

Protobuf.extensionDefaults(Duration, defaultSeq = true)

func computeFieldSize*(
    field: int, value: Duration, ProtoType: type ProtobufExt, skipDefault: static bool
): int =
  computeFieldSize(field, value.nanoseconds, pint64, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: Duration,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, value.nanoseconds, pint64, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var Duration,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  if header.kind() == wireKind(pint64):
    let intValue = stream.readValue(pint64).int64
    value = intValue.nanoseconds
    return true
  else:
    false

Protobuf.extensionDefaults(Moment, defaultSeq = true)

func computeFieldSize*(
    field: int, value: Moment, ProtoType: type ProtobufExt, skipDefault: static bool
): int =
  computeFieldSize(field, value.epochNanoSeconds(), pint64, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: Moment,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, value.epochNanoSeconds(), pint64, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var Moment,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  if header.kind() == wireKind(pint64):
    value = Moment.init(stream.readValue(pint64).int64, Nanosecond)
    return true
  else:
    false
