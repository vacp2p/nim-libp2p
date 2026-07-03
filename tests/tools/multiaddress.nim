# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../libp2p/[multiaddress]

template ma*(address: string): MultiAddress =
  MultiAddress.init(address).get()

template MemoryAutoAddress*(): MultiAddress =
  ma("/memorytransport/*")

template TcpAutoAddressIP4*(): MultiAddress =
  ma("/ip4/127.0.0.1/tcp/0")

template TcpAutoAddressIP6*(): MultiAddress =
  ma("/ip6/::1/tcp/0")

template TcpAutoAddress*(): MultiAddress =
  TcpAutoAddressIP4()

template WsAutoAddressIP4*(): MultiAddress =
  ma("/ip4/127.0.0.1/tcp/0/ws")

template WsAutoAddressIP6*(): MultiAddress =
  ma("/ip6/::1/tcp/0/ws")

template WsAutoAddress*(): MultiAddress =
  WsAutoAddressIP4()

template QuicAutoAddressIP4*(): MultiAddress =
  ma("/ip4/127.0.0.1/udp/0/quic-v1")

template QuicAutoAddressIP6*(): MultiAddress =
  ma("/ip6/::1/udp/0/quic-v1")

template QuicAutoAddress*(): MultiAddress =
  QuicAutoAddressIP4()

proc countAddressesWithPattern*(addrs: seq[MultiAddress], pattern: MaPattern): int =
  var count: int = 0
  for a in addrs:
    if pattern.match(a):
      count.inc
  count
