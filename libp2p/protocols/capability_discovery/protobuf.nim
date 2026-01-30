# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sets, times]
import chronos, results, stew/endians2
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress, routing_record]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../../extended_peer_record
import ../../signed_envelope
import ./types

# Helper procs for hex encoding/decoding
proc bytesToHex*(bytes: seq[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    let hexChars = "0123456789abcdef"
    result.add(hexChars[(b.int shr 4) and 0xF])
    result.add(hexChars[b.int and 0xF])

proc hexToBytes*(s: string): seq[byte] =
  result = newSeqOfCap[byte](s.len div 2)
  var i = 0
  while i < s.len:
    if i + 1 < s.len:
      let c1 = s[i].byte - '0'.byte
      let c2 = s[i + 1].byte - '0'.byte
      # Handle a-f
      let v1 =
        if c1 > 9:
          c1 - 39
        else:
          c1
      let v2 =
        if c2 > 9:
          c2 - 39
        else:
          c2
      result.add((v1.uint8 shl 4) or v2.uint8)
    i += 2

# XPR (Extensible Peer Record) for Logos Capability Discovery
# Uses ExtendedPeerRecord structure but with different domain/payload type per RFC

#TODO instead of the below logic, it would be best to modify extended_peer_record.nim

const
  XprRoutingDomain* = "libp2p-routing-state"
  XprPayloadType* = "/libp2p/extensible-peer-record/"

type XprAdvertisement* = SignedExtendedPeerRecord

proc xprPayloadDomain*(T: typedesc[XprAdvertisement]): string =
  ## Domain for XPR in Logos Capability Discovery
  XprRoutingDomain

proc xprPayloadTypeBytes*(): seq[byte] =
  ## Payload type for XPR in Logos Capability Discovery
  cast[seq[byte]](XprPayloadType)

proc createXprAdvertisement*(
    peerId: PeerId,
    addrs: seq[MultiAddress],
    serviceId: ServiceId,
    privateKey: PrivateKey,
    metadata: seq[byte] = @[],
): Result[XprAdvertisement, string] =
  ## Create an XPR-encoded advertisement for Logos Capability Discovery

  # Create service info from service ID
  # The service ID is SHA-256 hash of the protocol ID
  # We include it as the data field in ServiceInfo
  let serviceInfo = ServiceInfo(
    id: serviceId.bytesToHex(), # Store hex representation for identification
    data: metadata,
  )

  # Create ExtendedPeerRecord
  let extRecord = ExtendedPeerRecord.init(
    peerId = peerId,
    addresses = addrs,
    seqNo = getTime().toUnix().uint64,
    services = @[serviceInfo],
  )

  # Create signed envelope with correct domain and payload type
  let envelopeRes = Envelope.init(
    privateKey, xprPayloadTypeBytes(), extRecord.encode(), XprRoutingDomain
  )
  if envelopeRes.isErr:
    return err("Failed to create envelope: " & $envelopeRes.error)

  return ok(XprAdvertisement(envelope: envelopeRes.get(), data: extRecord))

proc verifyXprAdvertisement*(xpr: XprAdvertisement, serviceId: ServiceId): bool =
  ## Verify an XPR advertisement according to RFC spec:
  ## 1. Envelope domain == "libp2p-routing-state"
  ## 2. Payload type == "/libp2p/extensible-peer-record/"
  ## 3. Signature is valid
  ## 4. Service advertised matches serviceId

  # Check domain
  if xpr.envelope.domain != XprRoutingDomain:
    return false

  # Check payload type
  if xpr.envelope.payloadType != xprPayloadTypeBytes():
    return false

  # Check signature validity (already done during decode)
  # Check peer ID matches public key
  if not xpr.data.peerId.match(xpr.envelope.publicKey):
    return false

  # Check if service is advertised
  # We need to find the service that matches the serviceId
  let serviceIdHex = bytesToHex(serviceId)
  for service in xpr.data.services:
    # Check if the service ID hash matches
    if service.id == serviceIdHex:
      return true

  return false

proc toXprAdvertisement*(ad: Advertisement): Result[XprAdvertisement, string] =
  ## Convert an Advertisement to XPR format
  ## This requires the private key to sign, so caller must provide it
  ## Returns an error if we don't have the private key
  err(
    "Cannot convert Advertisement to XPR without private key - use createXprAdvertisement instead"
  )

proc toAdvertisement*(xpr: XprAdvertisement): Advertisement =
  ## Convert an XPR advertisement to the internal Advertisement format
  var serviceIdBytes: seq[byte]
  if xpr.data.services.len > 0:
    serviceIdBytes = hexToBytes(xpr.data.services[0].id)

  var addrs: seq[MultiAddress] = @[]
  for addrInfo in xpr.data.addresses:
    addrs.add(addrInfo.address)

  Advertisement(
    serviceId: serviceIdBytes,
    peerId: xpr.data.peerId,
    addrs: addrs,
    signature: xpr.envelope.signature.getBytes(),
    metadata:
      if xpr.data.services.len > 0:
        xpr.data.services[0].data
      else:
        @[],
    timestamp: xpr.data.seqNo.int64,
  )

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
