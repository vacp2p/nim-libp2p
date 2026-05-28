# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, chronicles, results
import ../crypto/crypto, ../peeridauth/client, ./utils

export PeerIDAuthError

logScope:
  topics = "libp2p autotls broker"

const
  DefaultBrokerURL* = "registration.libp2p.direct"
  HttpOk = 200

type AutotlsBroker* = ref object
  brokerURL: string
  peerIdAuthClient: PeerIDAuthClient
  bearer: Opt[BearerToken]

when defined(libp2p_autotls_support):
  import json, sequtils, times, uri
  import chronos/apps/http/httpcommon
  import ../peerinfo, ../multiaddress
  import ./acme/client

  proc new*(
      T: typedesc[AutotlsBroker],
      rng: Rng,
      brokerURL: string = DefaultBrokerURL,
      peerIdAuthClient: PeerIDAuthClient = PeerIDAuthClient.new(rng),
  ): T =
    T(
      brokerURL: brokerURL,
      peerIdAuthClient: peerIdAuthClient,
      bearer: Opt.none(BearerToken),
    )

  proc sendChallenge*(
      self: AutotlsBroker,
      peerInfo: PeerInfo,
      addrs: seq[MultiAddress],
      keyAuth: KeyAuthorization,
  ): Future[void] {.async: (raises: [AutoTLSError, PeerIDAuthError, CancelledError]).} =
    ## Authenticates with the AutoTLS broker and registers the ACME DNS-01
    ## challenge for the given addresses. All request construction, the broker
    ## URL, bearer-token handling and response validation are kept internal: the
    ## caller only learns whether the challenge was accepted (no error) or not
    ## (an exception).
    if addrs.len == 0:
      raise
        newException(AutoTLSError, "Unable to authenticate with broker: no addresses")

    let strMultiaddresses = addrs.mapIt($it)
    let payload = %*{"value": keyAuth, "addresses": strMultiaddresses}
    let registrationURL = parseUri("https://" & self.brokerURL & "/v1/_acme-challenge")

    # drop a bearer we already know to be expired so we re-authenticate
    # instead of looping on `PeerIDAuthError("Bearer expired")`
    if self.bearer.isSome():
      let cached = self.bearer.get()
      if cached.expires.isSome() and cached.expires.get() <= now():
        self.bearer = Opt.none(BearerToken)

    trace "Sending challenge to AutoTLS broker", brokerURL = self.brokerURL
    let (bearer, response) =
      await self.peerIdAuthClient.send(registrationURL, peerInfo, payload, self.bearer)
    # remember the latest bearer in case the broker rotated it
    self.bearer = Opt.some(bearer)

    if response.status != HttpOk:
      raise newException(
        AutoTLSError,
        "Failed to authenticate with AutoTLS broker " & self.brokerURL & " (status " &
          $response.status & "): " & bytesToString(response.body),
      )

  proc close*(self: AutotlsBroker) {.async: (raises: [CancelledError]).} =
    await self.peerIdAuthClient.close()
