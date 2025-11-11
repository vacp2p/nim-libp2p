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
import ./transports/test_all
import ./discovery/test_all
import ./kademlia/test_all
import ./mix/test_all

import
  testvarint, testminprotobuf, testmultibase, testmultihash, testmultiaddress, testcid,
  testpeerid, testsigned_envelope, testrouting_record, testnameresolve, testmultistream,
  testidentify, testobservedaddrmanager, testconnmngr, testswitch, testnoise,
  testpeerinfo, testpeerstore, testping, testmplex, testrelayv1, testrelayv2, testyamux,
  testyamuxheader, testautonat, testautonatservice, testautonatv2, testautonatv2service,
  testautorelay, testdcutr, testhpservice, testutility, testwildcardresolverservice,
  testperf

when defined(libp2p_autotls_support):
  import testautotls
