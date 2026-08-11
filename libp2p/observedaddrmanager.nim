# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import addressmanager
export addressmanager

type
  ObservedAddrManager* {.deprecated: "use AddressManager".} = AddressManager
  ObservedAddrManagerConfig* {.deprecated: "use AddressManagerConfig".} =
    AddressManagerConfig
