## Nim-Libp2p
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements Signed Envelope.

{.push raises: [Defect].}

import pkg/stew/[results, byteutils]
import multicodec,
       crypto/crypto,
       protobuf/minprotobuf,
       vbuffer

export crypto

type
  EnvelopeError* = enum
    EnvelopeInvalidProtobuf,
    EnvelopeFieldMissing,
    EnvelopeInvalidSignature

  Envelope* = object
    publicKey*: PublicKey
    domain*: string
    payloadType*: seq[byte]
    payload: seq[byte]
    signature*: Signature

proc mapProtobufError(e: ProtoError): EnvelopeError =
  case e:
    of RequiredFieldMissing:
      EnvelopeFieldMissing
    else:
      EnvelopeInvalidProtobuf

proc getSignatureBuffer(e: Envelope): seq[byte] =
  var buffer = initVBuffer()

  let domainBytes = e.domain.toBytes()
  buffer.writeSeq(domainBytes)
  buffer.writeSeq(e.payloadType)
  buffer.writeSeq(e.payload)
  
  buffer.buffer

proc decode*(T: typedesc[Envelope],
  buf: seq[byte],
  domain: string): Result[Envelope, EnvelopeError] =

  let pb = initProtoBuffer(buf)
  var envelope = Envelope()

  envelope.domain = domain
  ? pb.getRequiredField(1, envelope.publicKey).mapErr(mapProtobufError)
  discard ? pb.getField(2, envelope.payloadType).mapErr(mapProtobufError)
  ? pb.getRequiredField(3, envelope.payload).mapErr(mapProtobufError)
  ? pb.getRequiredField(5, envelope.signature).mapErr(mapProtobufError)

  if envelope.signature.verify(envelope.getSignatureBuffer(), envelope.publicKey) == false:
    err(EnvelopeInvalidSignature)
  else:
    ok(envelope)

proc init*(T: typedesc[Envelope],
    privateKey: PrivateKey,
    payloadType: seq[byte],
    payload: seq[byte],
    domain: string): Result[Envelope, CryptoError] =
  var envelope = Envelope(
    publicKey: ? privateKey.getPublicKey(),
    domain: domain,
    payloadType: payloadType,
    payload: payload,
  )

  envelope.signature = ? privateKey.sign(envelope.getSignatureBuffer())

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

proc getField*(pb: ProtoBuffer, field: int,
               value: var Envelope,
               domain: string): ProtoResult[bool] {.
     inline.} =
  var buffer: seq[byte]
  let res = ? pb.getField(field, buffer)
  if not(res):
    ok(false)
  else:
    let env = Envelope.decode(buffer, domain)
    if env.isOk():
      value = env.get()
      ok(true)
    else:
      err(ProtoError.IncorrectBlob)
