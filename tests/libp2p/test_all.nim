# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ./autotls/test_all
import ./crypto/test_all
import ./discovery/test_all
import ./kademlia/test_all
import ./mix/test_all
import ./multiformat/test_all
import ./muxers/test_all
import ./protocols/test_all
import ./pubsub/test_all
import ./services/test_all
import ./stream/test_all
import ./transports/test_all
import ./utils/test_all

import
  test_conn_manager, test_dialer, test_min_protobuf, test_multistream,
  test_name_resolve, test_observed_addr_manager, test_peer_id, test_peer_info,
  test_peer_store, test_routing_record, test_signed_envelope, test_switch, test_utility,
  test_varint, test_wire
