# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import json, sequtils, uri
import chronos, stew/byteutils
import
  ../../../libp2p/[
    autotls/broker,
    autotls/utils,
    autotls/acme/client,
    crypto/crypto,
    multiaddress,
    peerinfo,
  ]
import ../../tools/[unittest, crypto]
import ../../stubs/peer_id_auth_client_stub

suite "AutoTLS broker":
  const
    BrokerURL = "broker.example"
    RegistrationURL = "https://broker.example/v1/_acme-challenge"
    KeyAuth = KeyAuthorization("expected-key-authorization")

  var client {.threadvar.}: PeerIDAuthClientStub
  var broker {.threadvar.}: AutotlsBroker
  var peerInfo {.threadvar.}: PeerInfo
  var addrs {.threadvar.}: seq[MultiAddress]

  asyncTeardown:
    await broker.close()
    checkTrackers()

  asyncSetup:
    client = PeerIDAuthClientStub.new()
    broker = AutotlsBroker.new(rng(), BrokerURL, client)
    peerInfo = PeerInfo.new(PrivateKey.random(PKScheme.Ed25519, rng()).get())
    addrs = @[
      MultiAddress.init("/ip4/1.2.3.4/tcp/4001").get(),
      MultiAddress.init("/ip4/1.2.3.4/tcp/4002/ws").get(),
    ]

  asyncTest "an empty address set is refused before the broker is contacted":
    expect(AutoTLSError):
      await broker.sendChallenge(peerInfo, @[], KeyAuth)

    check client.requestedUris.len == 0

  asyncTest "the payload carries the key authorization and every address in order":
    await broker.sendChallenge(peerInfo, addrs, KeyAuth)

    check client.payloads.len == 1
    check parseJson(client.payloads[0]) ==
      %*{
        "value": KeyAuth,
        "addresses": ["/ip4/1.2.3.4/tcp/4001", "/ip4/1.2.3.4/tcp/4002/ws"],
      }

  asyncTest "the configured broker URL is the registration endpoint":
    await broker.sendChallenge(peerInfo, addrs, KeyAuth)

    check client.requestedUris.mapIt($it) == @[RegistrationURL, RegistrationURL]

  asyncTest "a rejected registration raises":
    client.status = 403
    client.body = "peer not authorized".toBytes()

    expect(AutoTLSError):
      await broker.sendChallenge(peerInfo, addrs, KeyAuth)
