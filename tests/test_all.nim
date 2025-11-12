# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ./tools/test_all
import ./utils/test_all
import ./crypto/test_all
import ./stream/test_all
import ./muxers/test_all
import ./transports/test_all
import ./discovery/test_all
import ./kademlia/test_all
import ./mix/test_all
import ./protocols/test_all
import ./pubsub/test_all

import
  testvarint, testminprotobuf, testmultibase, testmultihash, testmultiaddress, testcid,
  testpeerid, testsigned_envelope, testrouting_record, testnameresolve, testmultistream,
  testobservedaddrmanager, testconnmngr, testswitch, testpeerinfo, testpeerstore,
  testautorelay, testhpservice, testutility, testwildcardresolverservice

when defined(libp2p_autotls_support):
  import testautotls

# Run final trackers check. 
# After all tests are executed final trackers check is performed to ensure that 
# there isn't anything left open. 
# This can usually happen when last imported/executed tests do not call checkTrackers.
from ./tools/unittest import finalCheckTrackers
finalCheckTrackers()
