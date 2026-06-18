# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, protobuf_serialization, protobuf_serialization/extension

Protobuf.extensionDefaults(Duration, pint64, defaultSeq = true)

func computeFieldSize*(
    field: int, value: Duration, ProtoType: type ProtobufExt, skipDefault: static bool
): int =
  computeFieldSize(field, value.seconds, pint64, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: Duration,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, value.seconds, pint64, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var Duration,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  if header.kind() == wireKind(pint64):
    let intValue = stream.readValue(pint64).int64
    value = intValue.seconds
    return true
  else:
    false

func computeFieldSizePacked*(
    field: int, value: Duration, ProtoType: type ProtobufExt
): int =
  computeFieldSizePackedIt(field, value, pint64, it.seconds)

proc writeFieldPacked*(
    stream: OutputStream, field: int, value: Duration, ProtoType: type ProtobufExt
) {.raises: [IOError].} =
  writeFieldPackedIt(stream, field, value, pint64, it.seconds)

proc readFieldPackedInto*(
    stream: InputStream,
    value: var Duration,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  readFieldPackedIntoIt(stream, value, header, pint64):
    value.add it.seconds

Protobuf.extensionDefaults(Moment, pint64, defaultSeq = true)

func computeFieldSize*(
    field: int, value: Moment, ProtoType: type ProtobufExt, skipDefault: static bool
): int =
  computeFieldSize(field, value.epochSeconds(), pint64, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: Moment,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, value.epochSeconds(), pint64, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var Moment,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  if header.kind() == wireKind(pint64):
    value = Moment.init(stream.readValue(pint64).int64, Second)
    return true
  else:
    false

func computeFieldSizePacked*(
    field: int, value: Moment, ProtoType: type ProtobufExt
): int =
  computeFieldSizePackedIt(field, value, pint64, it.epochSeconds())

proc writeFieldPacked*(
    stream: OutputStream, field: int, value: Moment, ProtoType: type ProtobufExt
) {.raises: [IOError].} =
  writeFieldPackedIt(stream, field, value, pint64, it.epochSeconds())

proc readFieldPackedInto*(
    stream: InputStream,
    value: var Moment,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  readFieldPackedIntoIt(stream, value, header, pint64):
    value.add Moment.init(it, Second)
