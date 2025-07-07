# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronicles
import ./api
import ../../crypto/crypto

export api

type KeyAuthorization* = string

type ACMEClient* = ref object
  api: ACMEApi
  key*: KeyPair
  kid*: Kid

logScope:
  topics = "libp2p acme client"

when defined(libp2p_autotls_support):
  import uri
  import chronos, results, stew/byteutils
  import ./utils
  import ../../crypto/rsa

  proc new*(
      T: typedesc[ACMEClient],
      rng: ref HmacDrbgContext = newRng(),
      api: ACMEApi = ACMEApi.new(acmeServerURL = parseUri(LetsEncryptURL)),
      key: Opt[KeyPair] = Opt.none(KeyPair),
      kid: Kid = Kid(""),
  ): T {.raises: [].} =
    let key = key.valueOr:
      KeyPair.random(PKScheme.RSA, rng[]).get()
    T(api: api, key: key, kid: kid)

  proc getOrInitKid*(
      self: ACMEClient
  ): Future[Kid] {.async: (raises: [ACMEError, CancelledError]).} =
    if self.kid.len == 0:
      let registerResponse = await self.api.requestRegister(self.key)
      self.kid = registerResponse.kid
    return self.kid

  proc genKeyAuthorization*(self: ACMEClient, token: string): KeyAuthorization =
    base64UrlEncode(@(sha256.digest((token & "." & thumbprint(self.key)).toBytes).data))

  proc getChallenge*(
      self: ACMEClient, domains: seq[api.Domain]
  ): Future[ACMEChallengeResponseWrapper] {.
      async: (raises: [ACMEError, CancelledError])
  .} =
    await self.api.requestChallenge(domains, self.key, await self.getOrInitKid())

  proc getCertificate*(
      self: ACMEClient,
      domain: api.Domain,
      certKeyPair: KeyPair,
      challenge: ACMEChallengeResponseWrapper,
  ): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
    let chalURL = parseUri(challenge.dns01.url)
    let orderURL = parseUri(challenge.order)
    let finalizeURL = parseUri(challenge.finalize)
    trace "Sending challenge completed notification"
    discard await self.api.sendChallengeCompleted(
      chalURL, self.key, await self.getOrInitKid()
    )

    trace "Checking for completed challenge"
    let completed = await self.api.checkChallengeCompleted(
      chalURL, self.key, await self.getOrInitKid()
    )
    if not completed:
      raise newException(
        ACMEError, "Failed to signal ACME server about challenge completion"
      )

    trace "Waiting for certificate to be finalized"
    let finalized = await self.api.certificateFinalized(
      domain, finalizeURL, orderURL, certKeyPair, self.key, await self.getOrInitKid()
    )
    if not finalized:
      raise
        newException(ACMEError, "Failed to finalize certificate for domain " & domain)

    trace "Downloading certificate"
    await self.api.downloadCertificate(orderURL)

  proc close*(self: ACMEClient) {.async: (raises: [CancelledError]).} =
    await self.api.close()
