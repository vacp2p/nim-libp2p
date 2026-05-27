# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Minimal DNS message codec (RFC 1035).
##
## libp2p performs the UDP transport itself (see `dnsresolver`), so this module
## only deals with the wire format: building a query and decoding the answer
## records we care about (`A`, `AAAA`, `TXT`). It is pure bytes-in/bytes-out and
## raises only `ValueError` on malformed input.

{.push raises: [].}

import std/strutils
import stew/endians2
import ../utils/conversion

const
  MaxLabelLength = 63 # RFC 1035, section 2.3.4
  MaxNameLength = 255 # RFC 1035, section 3.1
  MaxPacketSize = 512 # RFC 1035, section 4.2.1
  HeaderSize = 12
  CompressionMask = 0xC0'u8
  QrMask = 0x8000'u16 # header flags: QR bit (1 = response)

template raiseErr(msg: string) =
  raise newException(ValueError, msg)

type
  DnsRecordKind* = enum
    A = 1
    TXT = 16
    AAAA = 28

  DnsAnswer* = object
    kind*: DnsRecordKind
    value*: string ## IPv4/IPv6 textual form, or concatenated TXT strings

  DnsReader = object
    data: seq[byte]
    pos: int

proc readByte(r: var DnsReader): uint8 {.raises: [ValueError].} =
  if r.pos >= r.data.len:
    raiseErr("Truncated DNS message")
  let value = r.data[r.pos]
  inc r.pos
  return value

proc readShort(r: var DnsReader): uint16 {.raises: [ValueError].} =
  if r.pos + 2 > r.data.len:
    raiseErr("Truncated DNS message")
  let value = fromBytesBE(uint16, r.data.toOpenArray(r.pos, r.pos + 1))
  inc r.pos, 2
  return value

proc readBytes(r: var DnsReader, n: int): seq[byte] {.raises: [ValueError].} =
  if n < 0 or r.pos + n > r.data.len:
    raiseErr("Truncated DNS message")
  let value = r.data[r.pos ..< r.pos + n]
  inc r.pos, n
  return value

proc skipName(r: var DnsReader) {.raises: [ValueError].} =
  ## Advances past a (possibly compressed) domain name. We never need the name's
  ## value — only to move the cursor to the bytes that follow it.
  var consumed = 0
  while true:
    let length = r.readByte()
    if length == 0:
      break
    case length and CompressionMask
    of 0x00'u8:
      # An ordinary label: the top two bits being clear bounds it to 63 bytes.
      discard r.readBytes(length.int)
      inc consumed, length.int + 1
      if consumed > MaxNameLength:
        raiseErr("DNS name too long")
    of CompressionMask:
      # A compression pointer is 2 bytes and always terminates the name.
      discard r.readByte()
      break
    else:
      # 0x40 / 0x80 are reserved label types (RFC 1035, section 4.1.4).
      raiseErr("Reserved DNS label type")

proc parseTxt(rdata: openArray[byte]): string {.raises: [ValueError].} =
  ## TXT rdata is a sequence of length-prefixed character-strings.
  var text: string
  var i = 0
  while i < rdata.len:
    let length = rdata[i].int
    inc i
    if i + length > rdata.len:
      raiseErr("Invalid TXT record")
    for j in 0 ..< length:
      text &= char(rdata[i + j])
    inc i, length
  return text

proc encodeQuery*(
    id: uint16, name: string, kind: DnsRecordKind
): seq[byte] {.raises: [ValueError].} =
  ## Builds a standard recursive query for `name`/`kind`.
  ## Raises `ValueError` on an illegal name (empty/oversized label or a name
  ## whose encoded form exceeds 255 bytes).
  var query = newSeqOfCap[byte](HeaderSize + name.len + 6)

  query.add(toBytesBE(id)) # id
  query.add([0x01'u8, 0x00'u8]) # flags: rd=1 (recursion desired)
  query.add([0x00'u8, 0x01'u8]) # qdcount = 1
  query.add([0x00'u8, 0x00'u8]) # ancount = 0
  query.add([0x00'u8, 0x00'u8]) # nscount = 0
  query.add([0x00'u8, 0x00'u8]) # arcount = 0

  var encodedNameLength = 1 # the root label terminator
  for label in name.split('.'):
    if label.len < 1:
      raiseErr(name & " is not a legal name (empty label)")
    if label.len > MaxLabelLength:
      raiseErr(name & " is not a legal name (label too long)")
    encodedNameLength += label.len + 1 # label bytes plus the length octet
    if encodedNameLength > MaxNameLength:
      raiseErr(name & " is not a legal name (encoded name too long)")
    query.add(label.len.uint8)
    for c in label:
      query.add(c.byte)
  query.add(0x00'u8) # root label terminator

  query.add(toBytesBE(kind.uint16)) # qtype
  query.add(toBytesBE(0x0001'u16)) # qclass = IN

  return query

proc parseAnswers*(
    data: openArray[byte], expectedId: uint16
): seq[DnsAnswer] {.raises: [ValueError].} =
  ## Parses the header and question, then decodes the answer section. Only
  ## `A`/`AAAA`/`TXT` answers are returned; other record types are skipped.
  ## `expectedId` is the id of the query this is a response to; a mismatch is
  ## rejected to guard against stale or spoofed datagrams.
  if data.len < HeaderSize:
    raiseErr("DNS response shorter than header")
  if data.len > MaxPacketSize:
    raiseErr("DNS response exceeds 512 bytes")

  var r = DnsReader(data: @data, pos: 0)

  if r.readShort() != expectedId:
    raiseErr("DNS response id does not match the query")
  if (r.readShort() and QrMask) == 0: # flags
    raiseErr("DNS message is not a response")
  let qdcount = r.readShort()
  if qdcount == 0:
    raiseErr("DNS response has no question")
  let ancount = r.readShort()
  discard r.readShort() # nscount
  discard r.readShort() # arcount

  # Skip the question section.
  for _ in 0 ..< qdcount.int:
    r.skipName()
    discard r.readShort() # qtype
    discard r.readShort() # qclass

  var answers: seq[DnsAnswer]
  for _ in 0 ..< ancount.int:
    r.skipName()
    let rrType = r.readShort()
    discard r.readShort() # class
    discard r.readShort() # ttl high
    discard r.readShort() # ttl low
    let rdlength = r.readShort().int
    let rdata = r.readBytes(rdlength)

    case rrType
    of A.uint16:
      if rdata.len != 4:
        raiseErr("Invalid A record")
      answers.add(DnsAnswer(kind: A, value: ipv4ToString(rdata)))
    of AAAA.uint16:
      if rdata.len != 16:
        raiseErr("Invalid AAAA record")
      answers.add(DnsAnswer(kind: AAAA, value: ipv6ToString(rdata)))
    of TXT.uint16:
      answers.add(DnsAnswer(kind: TXT, value: parseTxt(rdata)))
    else:
      discard # unsupported record type (e.g. CNAME), already skipped via rdlength

  return answers
