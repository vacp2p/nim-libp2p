# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sets]
import chronos, results, stew/endians2
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress, routing_record]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ./types

proc encode*(ad: Advertisement): seq[byte] =
  ## Encode Advertisement to protobuf format
  var pb = initProtoBuffer()
  pb.write(1, ad.serviceId)
  pb.write(2, ad.peerId)
  for addr in ad.addrs:
    pb.write(3, addr)
  if ad.signature.len > 0:
    pb.write(4, ad.signature)
  if ad.metadata.len > 0:
    pb.write(5, ad.metadata)
  pb.write(6, ad.timestamp.uint64)
  pb.finish()
  return pb.buffer

proc decode*(
    T: typedesc[Advertisement], buf: seq[byte]
): Result[Advertisement, ProtoError] =
  ## Decode Advertisement from protobuf format
  var pb = initProtoBuffer(buf)
  var ad = Advertisement(
    serviceId: @[],
    peerId: PeerId(data: @[]),
    addrs: @[],
    signature: @[],
    metadata: @[],
    timestamp: 0,
  )

  var serviceId: seq[byte]
  if ?pb.getField(1, serviceId):
    ad.serviceId = serviceId

  var peerId: PeerId
  if ?pb.getField(2, peerId):
    ad.peerId = peerId

  var addrs: seq[MultiAddress]
  discard ?pb.getRepeatedField(3, addrs)
  ad.addrs = addrs

  var signature: seq[byte]
  if ?pb.getField(4, signature):
    ad.signature = signature

  var metadata: seq[byte]
  if ?pb.getField(5, metadata):
    ad.metadata = metadata

  var timestamp: uint64
  if ?pb.getField(6, timestamp):
    ad.timestamp = timestamp.int64

  ok(ad)

proc sign*(ad: var Advertisement, privateKey: PrivateKey): Result[void, CryptoError] =
  ## Sign the advertisement with the given private key.
  ## Signature is over: service_id_hash || peerID || addrs
  var sigInput = newSeqOfCap[byte](ad.serviceId.len + ad.peerId.data.len)
  sigInput.add(ad.serviceId)
  sigInput.add(ad.peerId.data)
  for addr in ad.addrs:
    sigInput.add(addr.data.buffer)

  let sig = ?privateKey.sign(sigInput)
  ad.signature = sig.getBytes()
  ok()

proc verify*(ad: Advertisement, publicKey: PublicKey): bool =
  ## Verify the advertisement signature with the given public key.
  var sigInput = newSeqOfCap[byte](ad.serviceId.len + ad.peerId.data.len)
  sigInput.add(ad.serviceId)
  sigInput.add(ad.peerId.data)
  for addr in ad.addrs:
    sigInput.add(addr.data.buffer)

  var sig: Signature
  if not sig.init(ad.signature):
    return false
  sig.verify(sigInput, publicKey)

proc encode*(ticket: Ticket): seq[byte] =
  ## Encode Ticket to protobuf format
  var pb = initProtoBuffer()
  pb.write(1, ticket.ad.encode())
  pb.write(2, ticket.t_init.uint64)
  pb.write(3, ticket.t_mod.uint64)
  pb.write(4, ticket.t_wait_for)
  if ticket.signature.len > 0:
    pb.write(5, ticket.signature)
  pb.finish()
  return pb.buffer

proc decode*(T: typedesc[Ticket], buf: seq[byte]): Result[Ticket, ProtoError] =
  ## Decode Ticket from protobuf format
  var pb = initProtoBuffer(buf)
  var ticket = Ticket(
    ad: Advertisement(
      serviceId: @[],
      peerId: PeerId(data: @[]),
      addrs: @[],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    ),
    t_init: 0,
    t_mod: 0,
    t_wait_for: 0,
    signature: @[],
  )

  var adBuf: seq[byte]
  if ?pb.getField(1, adBuf):
    let ad = ?Advertisement.decode(adBuf)
    ticket.ad = ad

  var tInit: uint64
  if ?pb.getField(2, tInit):
    ticket.t_init = tInit.int64

  var tMod: uint64
  if ?pb.getField(3, tMod):
    ticket.t_mod = tMod.int64

  var tWaitFor: uint32
  if ?pb.getField(4, tWaitFor):
    ticket.t_wait_for = tWaitFor

  var signature: seq[byte]
  if ?pb.getField(5, signature):
    ticket.signature = signature

  ok(ticket)

proc sign*(ticket: var Ticket, privateKey: PrivateKey): Result[void, CryptoError] =
  ## Sign the ticket with the given private key.
  ## Signature is over: encoded_ad || t_init || t_mod || t_wait_for
  var sigInput = ticket.ad.encode()
  sigInput.add(toBytesBE(ticket.t_init.uint64))
  sigInput.add(toBytesBE(ticket.t_mod.uint64))
  sigInput.add(toBytesBE(ticket.t_wait_for.uint32))

  let sig = ?privateKey.sign(sigInput)
  ticket.signature = sig.getBytes()
  ok()

proc verify*(ticket: Ticket, publicKey: PublicKey): bool =
  ## Verify the ticket signature with the given public key.
  var sigInput = ticket.ad.encode()
  sigInput.add(toBytesBE(ticket.t_init.uint64))
  sigInput.add(toBytesBE(ticket.t_mod.uint64))
  sigInput.add(toBytesBE(ticket.t_wait_for.uint32))

  var sig: Signature
  if not sig.init(ticket.signature):
    return false
  sig.verify(sigInput, publicKey)
