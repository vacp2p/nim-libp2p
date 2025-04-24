# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements Signed Envelope.

{.push raises: [].}

import std/sugar
import pkg/stew/byteutils, pkg/results
import multicodec, crypto/crypto, protobuf/minprotobuf, vbuffer

export crypto

type
  EnvelopeError* = enum
    EnvelopeInvalidProtobuf
    EnvelopeFieldMissing
    EnvelopeInvalidSignature
    EnvelopeWrongType

  Envelope* = object
    publicKey*: PublicKey
    domain*: string
    payloadType*: seq[byte]
    payload: seq[byte]
    signature*: Signature

proc mapProtobufError(e: ProtoError): EnvelopeError =
  case e
  of RequiredFieldMissing: EnvelopeFieldMissing
  else: EnvelopeInvalidProtobuf

proc getSignatureBuffer(e: Envelope): seq[byte] =
  var buffer = initVBuffer()

  let domainBytes = e.domain.toBytes()
  buffer.writeSeq(domainBytes)
  buffer.writeSeq(e.payloadType)
  buffer.writeSeq(e.payload)

  buffer.buffer

proc decode*(
    T: typedesc[Envelope], buf: seq[byte], domain: string
): Result[Envelope, EnvelopeError] =
  let pb = initProtoBuffer(buf)
  var envelope = Envelope()

  envelope.domain = domain
  ?pb.getRequiredField(1, envelope.publicKey).mapErr(mapProtobufError)
  discard ?pb.getField(2, envelope.payloadType).mapErr(mapProtobufError)
  ?pb.getRequiredField(3, envelope.payload).mapErr(mapProtobufError)
  ?pb.getRequiredField(5, envelope.signature).mapErr(mapProtobufError)

  if envelope.signature.verify(envelope.getSignatureBuffer(), envelope.publicKey) ==
      false:
    err(EnvelopeInvalidSignature)
  else:
    ok(envelope)

proc init*(
    T: typedesc[Envelope],
    privateKey: PrivateKey,
    payloadType: seq[byte],
    payload: seq[byte],
    domain: string,
): Result[Envelope, CryptoError] =
  var envelope = Envelope(
    publicKey: ?privateKey.getPublicKey(),
    domain: domain,
    payloadType: payloadType,
    payload: payload,
  )

  envelope.signature = ?privateKey.sign(envelope.getSignatureBuffer())

  ok(envelope)

proc encode*(env: Envelope): Result[seq[byte], CryptoError] =
  var pb = initProtoBuffer()

  try:
    pb.write(1, env.publicKey)
    pb.write(2, env.payloadType)
    pb.write(3, env.payload)
    pb.write(5, env.signature)
  except ResultError[CryptoError] as exc:
    return err(exc.error)

  pb.finish()
  ok(pb.buffer)

proc payload*(env: Envelope): seq[byte] =
  # Payload is readonly
  env.payload

proc getField*(
    pb: ProtoBuffer, field: int, value: var Envelope, domain: string
): ProtoResult[bool] {.inline.} =
  var buffer: seq[byte]
  let res = ?pb.getField(field, buffer)
  if not (res):
    ok(false)
  else:
    value = Envelope.decode(buffer, domain).valueOr:
      return err(ProtoError.IncorrectBlob)
    ok(true)

proc write*(pb: var ProtoBuffer, field: int, env: Envelope): Result[void, CryptoError] =
  let e = ?env.encode()
  pb.write(field, e)
  ok()

type SignedPayload*[T] = object
  # T needs to have .encode(), .decode(), .payloadType(), .domain()
  envelope*: Envelope
  data*: T

proc init*[T](
    _: typedesc[SignedPayload[T]], privateKey: PrivateKey, data: T
): Result[SignedPayload[T], CryptoError] =
  mixin encode

  let envelope =
    ?Envelope.init(privateKey, T.payloadType(), data.encode(), T.payloadDomain)

  ok(SignedPayload[T](data: data, envelope: envelope))

proc getField*[T](
    pb: ProtoBuffer, field: int, value: var SignedPayload[T]
): ProtoResult[bool] {.inline.} =
  if not ?getField(pb, field, value.envelope, T.payloadDomain):
    ok(false)
  else:
    mixin decode
    value.data = ?T.decode(value.envelope.payload).mapErr(x => ProtoError.IncorrectBlob)
    ok(true)

proc decode*[T](
    _: typedesc[SignedPayload[T]], buffer: seq[byte]
): Result[SignedPayload[T], EnvelopeError] =
  let
    envelope = ?Envelope.decode(buffer, T.payloadDomain)
    data = ?T.decode(envelope.payload).mapErr(x => EnvelopeInvalidProtobuf)
    signedPayload = SignedPayload[T](envelope: envelope, data: data)

  if envelope.payloadType != T.payloadType:
    return err(EnvelopeWrongType)

  when compiles(?signedPayload.checkValid()):
    ?signedPayload.checkValid()

  ok(signedPayload)

proc encode*[T](msg: SignedPayload[T]): Result[seq[byte], CryptoError] =
  msg.envelope.encode()
