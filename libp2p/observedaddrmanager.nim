# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import address_manager
export address_manager

type
  ObservedAddrManager* {.deprecated: "use AddressManager".} = AddressManager
  ObservedAddrManagerConfig* {.deprecated: "use AddressManagerConfig".} =
    AddressManagerConfig
