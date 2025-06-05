{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos
import chronos/apps/http/httpclient
import ../libp2p/[stream/connection, upgrademngrs/upgrade, peeridauth, wire]

import ./helpers

const AuthPeerURL = "https://registration.libp2p.direct/v1/_acme-challenge"

suite "PeerID Auth":
  var api {.threadvar.}: PeerIDAuthApi
  var peerInfo {.threadvar.}: PeerInfo

  asyncTeardown:
    await api.close()
    checkTrackers()

  asyncSetup:
    let rng = newRng()
    api = PeerIDAuthApi.new(rng[])
    peerInfo = PeerInfo.new(KeyPair.random(PKScheme.RSA, rng[]).get())

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

    # check without bearer
    let bearer = await api.send(peerInfo, AuthPeerURL, payload)
    check bearer.len > 0

    # check with bearer
    api.bearer = Opt.some(bearer)
    let bearer = await api.send(peerInfo, AuthPeerURL, payload)
    # TODO: check if thing was sent
    check false
