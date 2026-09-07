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
    # 128 single-char labels: each label is legal, but the encoded name (257
    # bytes) exceeds the RFC 1035 255-byte limit.
    expect ValueError:
      discard encodeQuery(0, strutils.repeat("a.", 127) & "a", A)

  test "parseAnswers decodes A records (with compression)":
    let answers = parseAnswers(statusImA.toBytes(), 0xaebf'u16)
    check answers.allIt(it.kind == A)
    check answers.mapIt(initTAddress(it.value, Port(0))) ==
      @["104.22.24.181", "172.67.10.161", "104.22.25.181"].mapIt(
        initTAddress(it, Port(0))
      )

  test "parseAnswers decodes AAAA records (with compression)":
    let answers = parseAnswers(statusImAAAA.toBytes(), 0xe8c5'u16)
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
    let answers = parseAnswers(txt, 0x0001'u16)
    check answers.len == 1
    check answers[0].kind == TXT
    check answers[0].value == "helloworld"

  test "parseAnswers rejects malformed input without defects":
    expect ValueError:
      discard parseAnswers(@[0x00'u8, 0x01, 0x02], 0) # shorter than header
    # qdcount=1/ancount=1, but the message is truncated right after the header
    let truncated =
      @[0x00'u8, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
    expect ValueError:
      discard parseAnswers(truncated, 0x0001'u16)

  test "parseAnswers rejects a response whose id does not match the query":
    expect ValueError:
      discard parseAnswers(statusImA.toBytes(), 0x0000'u16)

  test "parseAnswers rejects a message that is not a response":
    # QR bit clear in the flags (0x0100 = query, rd=1)
    let query =
      @[0x00'u8, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    expect ValueError:
      discard parseAnswers(query, 0x0001'u16)

  test "parseAnswers rejects a response without a question":
    let noQuestion =
      @[0x00'u8, 0x01, 0x81, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    expect ValueError:
      discard parseAnswers(noQuestion, 0x0001'u16)

  test "parseAnswers rejects an A record with the wrong length":
    let badA = @[
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
      0x00,
      0x01,
      ord('x').uint8,
      0x00,
      0x00,
      0x01,
      0x00,
      0x01, # question: "x", A, IN
      0xc0,
      0x0c,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x03,
      0x01,
      0x02,
      0x03, # answer: A, IN, rdlength=3 (invalid), 3 bytes rdata
    ]
    expect ValueError:
      discard parseAnswers(badA, 0x0001'u16)

  test "parseAnswers rejects a reserved DNS label type":
    # question label starts with 0x40 (reserved label type, top two bits 01)
    let reserved = @[
      0x00'u8, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40,
      0x00,
    ]
    expect ValueError:
      discard parseAnswers(reserved, 0x0001'u16)

suite "DNS message codec: whole messages":
  test "encodeMessage and parseMessage round-trip a query":
    let query =
      DnsMessage(questions: @[DnsQuestion(name: "_p2p._udp.local", kind: PTR)])
    let decoded = parseMessage(encodeMessage(query))
    check:
      not decoded.response
      decoded.questions == query.questions
      decoded.answers.len == 0

  test "encodeMessage and parseMessage round-trip a DNS-SD response":
    let response = DnsMessage(
      response: true,
      answers: @[
        DnsRecord(
          name: "_p2p._udp.local", kind: PTR, ttl: 120, value: "abc._p2p._udp.local"
        )
      ],
      additionals: @[
        DnsRecord(
          name: "abc._p2p._udp.local",
          kind: TXT,
          ttl: 120,
          strings: @["dnsaddr=/ip4/1.2.3.4/tcp/1", "dnsaddr=/ip6/::1/tcp/2"],
        ),
        DnsRecord(
          name: "abc._p2p._udp.local",
          kind: SRV,
          ttl: 120,
          port: 4001,
          value: "abc.local",
        ),
        DnsRecord(name: "abc.local", kind: A, ttl: 120, value: "1.2.3.4"),
        DnsRecord(name: "abc.local", kind: AAAA, ttl: 120, value: "::1"),
      ],
    )
    let decoded = parseMessage(encodeMessage(response))
    check:
      decoded.response
      decoded.answers == response.answers
      decoded.additionals == response.additionals

  test "parseMessage keeps the cursor after a compressed name":
    # PTR answer whose name is the 0xc00c pointer and whose target is
    # "x" + a pointer back to the question name.
    let message = @[
      0x00'u8,
      0x00,
      0x84,
      0x00,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x01,
      ord('a').uint8,
      0x00,
      0x00,
      0x0c,
      0x00,
      0x01, # question: "a", PTR, IN
      0xc0,
      0x0c,
      0x00,
      0x0c,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x0a,
      0x00,
      0x04,
      0x01,
      ord('x').uint8,
      0xc0,
      0x0c, # answer: PTR ttl=10 -> "x.a"
      0x01,
      ord('x').uint8,
      0xc0,
      0x0c,
      0x00,
      0x10,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x0a,
      0x00,
      0x03,
      0x02,
      ord('h').uint8,
      ord('i').uint8, # additional: "x.a" TXT "hi"
    ]
    let decoded = parseMessage(message)
    check:
      decoded.answers.len == 1
      decoded.answers[0].name == "a"
      decoded.answers[0].kind == PTR
      decoded.answers[0].ttl == 10
      decoded.answers[0].value == "x.a"
      decoded.additionals.len == 1
      decoded.additionals[0].name == "x.a"
      decoded.additionals[0].strings == @["hi"]

  test "parseMessage skips an unknown record type":
    # an=2: a CNAME answer for "a", then a PTR answer for "a" -> "b"
    let withCname = @[
      0x00'u8,
      0x00,
      0x84,
      0x00,
      0x00,
      0x00,
      0x00,
      0x02,
      0x00,
      0x00,
      0x00,
      0x00,
      0x01,
      ord('a').uint8,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x03,
      0x01,
      ord('b').uint8,
      0x00,
      0x01,
      ord('a').uint8,
      0x00,
      0x00,
      0x0c,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x03,
      0x01,
      ord('b').uint8,
      0x00,
    ]
    let decoded = parseMessage(withCname)
    check:
      decoded.answers.len == 1
      decoded.answers[0].kind == PTR
      decoded.answers[0].name == "a"
      decoded.answers[0].value == "b"

  test "parseMessage rejects a compression loop":
    let loop = @[
      0x00'u8,
      0x00,
      0x84,
      0x00,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0xc0,
      0x0c, # answer name points at itself
    ]
    expect ValueError:
      discard parseMessage(loop)

  test "encodeMessage rejects a TXT string above 255 bytes":
    let big = DnsMessage(
      response: true,
      answers: @[
        DnsRecord(
          name: "a.local", kind: TXT, ttl: 1, strings: @[strutils.repeat("x", 256)]
        )
      ],
    )
    expect ValueError:
      discard encodeMessage(big)
