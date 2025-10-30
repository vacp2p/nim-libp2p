# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  testvarint, testconnection, testbridgestream, testminprotobuf, testsemaphore,
  testheartbeat, testfuture, testzeroqueue, testbytesview

import testminasn1, testrsa, testecnist, tested25519, testsecp256k1, testcrypto

import
  testmultibase, testmultihash, testmultiaddress, testipaddr, testcid, testpeerid,
  testsigned_envelope, testrouting_record

import transports/testtransports

import
  testnameresolve, testmultistream, testbufferstream, testidentify,
  testobservedaddrmanager, testconnmngr, testswitch, testnoise, testpeerinfo,
  testpeerstore, testping, testmplex, testrelayv1, testrelayv2, testyamux,
  testyamuxheader, testautonat, testautonatservice, testautonatv2, testautonatv2service,
  testautorelay, testdcutr, testhpservice, testutility, testhelpers,
  testwildcardresolverservice, testperf, testpkifilter

import discovery/testdiscovery

import
  kademlia/[
    testencoding, testroutingtable, testfindnode, testputval, testgetval, testprovider,
    testping,
  ]

when defined(libp2p_autotls_support):
  import testautotls

import
  mix/[
    testcrypto, testcurve25519, testtagmanager, testseqnogenerator, testserialization,
    testmixmessage, testsphinx, testmultiaddr, testfragmentation, testmixnode, testconn,
  ]
