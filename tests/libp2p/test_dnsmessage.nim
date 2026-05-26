# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[sequtils, strutils]
import chronos
import ../../libp2p/nameresolving/dnsmessage
import ../tools/[unittest]

# Real status.im responses captured for the resolver tests; they use the
# `\xc0\x0c` compression pointer for answer names, so they double as compression
# coverage for the codec.
const statusImA =
  "\xae\xbf\x81\x80\x00\x01\x00\x03\x00\x00\x00\x00\x06\x73\x74\x61" &
  "\x74\x75\x73\x02\x69\x6d\x00\x00\x01\x00\x01\xc0\x0c\x00\x01\x00" &
  "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x18\xb5\xc0\x0c\x00\x01\x00" &
  "\x01\x00\x00\x00\x4f\x00\x04\xac\x43\x0a\xa1\xc0\x0c\x00\x01\x00" &
  "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x19\xb5"

const statusImAAAA =
  "\xe8\xc5\x81\x80\x00\x01\x00\x03\x00\x00\x00\x00\x06\x73\x74\x61" &
  "\x74\x75\x73\x02\x69\x6d\x00\x00\x1c\x00\x01\xc0\x0c\x00\x1c\x00" &
  "\x01\x00\x00\x00\x4f\x00\x10\x26\x06\x47\x00\x00\x10\x00\x00\x00" &
  "\x00\x00\x00\x68\x16\x19\xb5\xc0\x0c\x00\x1c\x00\x01\x00\x00\x00" &
  "\x4f\x00\x10\x26\x06\x47\x00\x00\x10\x00\x00\x00\x00\x00\x00\x68" &
  "\x16\x18\xb5\xc0\x0c\x00\x1c\x00\x01\x00\x00\x00\x4f\x00\x10\x26" &
  "\x06\x47\x00\x00\x10\x00\x00\x00\x00\x00\x00\xac\x43\x0a\xa1"

proc toBytes(s: string): seq[byte] =
  cast[seq[byte]](s)

suite "DNS message codec":
  test "encodeQuery builds a recursive A query":
    let q = encodeQuery(0x1234'u16, "status.im", A)
    check:
      q[0 .. 1] == @[0x12'u8, 0x34] # id
      q[2 .. 3] == @[0x01'u8, 0x00] # flags: rd=1
      q[4 .. 5] == @[0x00'u8, 0x01] # qdcount=1
      q[6 .. 11] == @[0x00'u8, 0x00, 0x00, 0x00, 0x00, 0x00] # an/ns/ar = 0
      # question: labels "status"."im", root, qtype=A, qclass=IN
      q[12 .. ^1] ==
        @[
          0x06'u8,
          ord('s').uint8,
          ord('t').uint8,
          ord('a').uint8,
          ord('t').uint8,
          ord('u').uint8,
          ord('s').uint8,
          0x02,
          ord('i').uint8,
          ord('m').uint8,
          0x00,
          0x00,
          0x01,
          0x00,
          0x01,
        ]

  test "encodeQuery rejects illegal names":
    expect ValueError:
      discard encodeQuery(0, "", A)
    expect ValueError:
      discard encodeQuery(0, "host..domain", A)
    expect ValueError:
      discard encodeQuery(0, strutils.repeat("a", 64) & ".com", A)

  test "parseAnswers decodes A records (with compression)":
    let answers = parseAnswers(statusImA.toBytes())
    check answers.allIt(it.kind == A)
    check answers.mapIt(initTAddress(it.value, Port(0))) ==
      @["104.22.24.181", "172.67.10.161", "104.22.25.181"].mapIt(
        initTAddress(it, Port(0))
      )

  test "parseAnswers decodes AAAA records (with compression)":
    let answers = parseAnswers(statusImAAAA.toBytes())
    check answers.allIt(it.kind == AAAA)
    check answers.mapIt(initTAddress(it.value, Port(0))) ==
      @["2606:4700:10::6816:19b5", "2606:4700:10::6816:18b5", "2606:4700:10::ac43:aa1"].mapIt(
        initTAddress(it, Port(0))
      )

  test "parseAnswers decodes and concatenates TXT records":
    # header: id, flags=0x8180, qd=1, an=1; question "x"; answer via 0xc00c pointer
    let txt = @[
      0x00'u8,
      0x01,
      0x81,
      0x80,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00, # question: "x", TXT, IN
      0x01,
      ord('x').uint8,
      0x00,
      0x00,
      0x10,
      0x00,
      0x01, # answer: name ptr -> 0x0c, TXT, IN, ttl=0, rdlength=12
      0xc0,
      0x0c,
      0x00,
      0x10,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x0c, # rdata: "hello" + "world"
      0x05,
      ord('h').uint8,
      ord('e').uint8,
      ord('l').uint8,
      ord('l').uint8,
      ord('o').uint8,
      0x05,
      ord('w').uint8,
      ord('o').uint8,
      ord('r').uint8,
      ord('l').uint8,
      ord('d').uint8,
    ]
    let answers = parseAnswers(txt)
    check answers.len == 1
    check answers[0].kind == TXT
    check answers[0].value == "helloworld"

  test "parseAnswers rejects malformed input without defects":
    expect ValueError:
      discard parseAnswers(@[0x00'u8, 0x01, 0x02]) # shorter than header
    # ancount claims an answer, but the message is truncated mid-record
    let truncated =
      @[0x00'u8, 0x01, 0x81, 0x80, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
    expect ValueError:
      discard parseAnswers(truncated)
