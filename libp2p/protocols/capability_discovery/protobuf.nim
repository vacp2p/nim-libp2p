# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sets, sequtils]
import chronos, results, stew/endians2
import
  ../../[
    peerid, switch, multihash, cid, multicodec, routing_record, extended_peer_record,
  ]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../../signed_envelope
import ./types

proc encode*(ticket: Ticket): seq[byte] =
  ## Encode Ticket to protobuf format
  var pb = initProtoBuffer()
  pb.write(1, ticket.ad)
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
  var ticket = Ticket()

  var adBuf: seq[byte]
  if ?pb.getField(1, adBuf):
    ticket.ad = adBuf

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
  var sigInput = newSeqOfCap[byte](ticket.ad.len + 8 + 8 + 4)
  sigInput.add(ticket.ad)
  sigInput.add(toBytesBE(ticket.t_init.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.t_mod.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.t_wait_for.uint32).toSeq)

  let sig = ?privateKey.sign(sigInput)
  ticket.signature = sig.getBytes()
  ok()

proc verify*(ticket: Ticket, publicKey: PublicKey): bool =
  ## Verify the ticket signature with the given public key.
  var sigInput = newSeqOfCap[byte](ticket.ad.len + 8 + 8 + 4)
  sigInput.add(ticket.ad)
  sigInput.add(toBytesBE(ticket.t_init.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.t_mod.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.t_wait_for.uint32).toSeq)

  var sig: Signature
  if not sig.init(ticket.signature):
    return false
  sig.verify(sigInput, publicKey)
