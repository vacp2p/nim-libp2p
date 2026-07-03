# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/net

proc safeConvert*[T: SomeInteger](value: SomeOrdinal): T =
  type S = typeof(value)
  ## Converts `value` from S to `T` iff `value` is guaranteed to be preserved.
  when int64(T.low) <= int64(S.low()) and uint64(T.high) >= uint64(S.high):
    T(value)
  else:
    {.error: "Source and target types have an incompatible range low..high".}

func ipv4ToString*(bytes: openArray[byte]): string {.raises: [ValueError].} =
  ## Renders 4 network-order bytes as a dotted-decimal IPv4 address,
  ## e.g. `"1.2.3.4"`. Raises `ValueError` if `bytes` is not 4 bytes long.
  if bytes.len != 4:
    raise newException(ValueError, "IPv4 address must be 4 bytes")
  var ip = IpAddress(family: IpAddressFamily.IPv4)
  for i in 0 ..< ip.address_v4.len:
    ip.address_v4[i] = bytes[i]
  return $ip

func ipv6ToString*(bytes: openArray[byte]): string {.raises: [ValueError].} =
  ## Renders 16 network-order bytes as a compressed IPv6 address,
  ## e.g. `"2606:4700:10::6816:19b5"`. Raises `ValueError` if `bytes` is not
  ## 16 bytes long.
  if bytes.len != 16:
    raise newException(ValueError, "IPv6 address must be 16 bytes")
  var ip = IpAddress(family: IpAddressFamily.IPv6)
  for i in 0 ..< ip.address_v6.len:
    ip.address_v6[i] = bytes[i]
  return $ip
