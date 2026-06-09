# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import results
import chronos
import
  ../../protocol,
  ../../../switch,
  ../../../multiaddress,
  ../../../multicodec,
  ../../../peerid,
  ./types

proc asNetworkReachability*(self: DialResponse): NetworkReachability =
  self.status.withValue(status):
    if status == EInternalError:
      return Unknown
    if status == ERequestRejected:
      return Unknown
    if status == EDialRefused:
      return Unknown

  # if got here it means a dial was attempted
  let dialStatus = self.dialStatus.valueOr:
    return Unknown
  if dialStatus == Unused:
    return Unknown
  if dialStatus == EDialError:
    return NotReachable
  if dialStatus == EDialBackError:
    return NotReachable
  return Reachable

proc asAutonatV2Response*(
    self: DialResponse, testAddrs: seq[MultiAddress]
): AutonatV2Response =
  let addrIdx = self.addrIdx.valueOr:
    return AutonatV2Response(
      reachability: self.asNetworkReachability(),
      dialResp: self,
      addrs: Opt.none(MultiAddress),
    )
  AutonatV2Response(
    reachability: self.asNetworkReachability(),
    dialResp: self,
    addrs: Opt.some(testAddrs[addrIdx]),
  )
