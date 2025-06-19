# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import uri
import chronos, results, bio

import ./api, ./utils
import ../../crypto/crypto
import ../../crypto/rsa

export api

type KeyAuthorization* = string

type ACMEClient* = object
  api: ACMEApi
  key*: KeyPair
  kid*: Kid

proc new*(
    T: typedesc[ACMEClient],
    api: Opt[ACMEApi] = Opt.none(ACMEApi),
    key: Opt[KeyPair] = Opt.none(KeyPair),
    rng: ref HmacDrbgContext = newRng(),
    acmeServerURL: Uri = parseUri(LetsEncryptURL),
): Future[T] {.async: (raises: [ACMEError, CancelledError]).} =
  let api = api.valueOr:
    ACMEApi.new()
  let key = key.valueOr:
    KeyPair.random(PKScheme.RSA, rng[]).get()
  let registerResponse = await api.requestRegister(key)
  T(api: api, key: key, kid: registerResponse.kid)

proc genKeyAuthorization*(self: ACMEClient, token: string): KeyAuthorization =
  base64UrlEncode(@(sha256.digest((token & "." & thumbprint(self.key)).toByteSeq).data))

proc getChallenge*(
    self: ACMEClient, domains: seq[api.Domain]
): Future[ACMEChallengeResponseWrapper] {.async: (raises: [ACMEError, CancelledError]).} =
  await self.api.requestChallenge(domains, self.key, self.kid)

proc getCertificate*(
    self: ACMEClient, domain: api.Domain, challenge: ACMEChallengeResponseWrapper
): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let chalURL = parseUri(challenge.dns01.url)
  let orderURL = parseUri(challenge.order)
  let finalizeURL = parseUri(challenge.finalize)
  discard await self.api.sendChallengeCompleted(chalURL, self.key, self.kid)

  let completed = await self.api.checkChallengeCompleted(chalURL, self.key, self.kid)
  if not completed:
    raise
      newException(ACMEError, "Failed to signal ACME server about challenge completion")

  let finalized = await self.api.certificateFinalized(
    domain, finalizeURL, orderURL, self.key, self.kid
  )
  if not finalized:
    raise newException(ACMEError, "Failed to finalize certificate for domain " & domain)

  await self.api.downloadCertificate(orderURL)

proc close*(self: ACMEClient): Future[void] {.async: (raises: [CancelledError]).} =
  await self.api.close()
