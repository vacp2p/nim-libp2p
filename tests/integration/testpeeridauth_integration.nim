# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import json, uri
import chronos
import chronos/apps/http/httpclient
import ../../libp2p/[stream/connection, upgrademngrs/upgrade, peeridauth, wire]

import ../helpers

when defined(linux) and defined(amd64):
  {.used.}

const
  AuthPeerURL = "https://registration.libp2p.direct/v1/_acme-challenge"
  HttpPeerAuthFailed = 401

suite "PeerID Auth":
  var client {.threadvar.}: PeerIDAuthClient
  var peerInfo {.threadvar.}: PeerInfo

  asyncTeardown:
    await client.close()
    checkTrackers()

  asyncSetup:
    let rng = newRng()
    client = PeerIDAuthClient.new(rng)
    peerInfo = PeerInfo.new(PrivateKey.random(PKScheme.RSA, rng[]).get())

  asyncTest "test peerID send":
    let payload =
      %*{
        "identifiers": [
          {
            "type": "dns",
            "value":
              "*.k51qzi5uqu5dj8c5nhiw2oceam0uebustsj7s36kjxwtscngp0y126o3b95mh9.libp2p.direct",
          }
        ]
      }

    let (bearer, responseWithoutBearer) =
      await client.send(parseUri(AuthPeerURL), peerInfo, payload)
    check responseWithoutBearer.status != HttpPeerAuthFailed
    doAssert bearer.token.len > 0

    let (_, responseWithBearer) =
      await client.send(parseUri(AuthPeerURL), peerInfo, payload, bearer)
    check responseWithBearer.status != HttpPeerAuthFailed
