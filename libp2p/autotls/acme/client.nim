# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import uri
import nimcrypto/sha2
import chronos, chronicles, results, stew/byteutils
import ../../crypto/rsa
import ../../crypto/rng
import ../../utils/opt
import ./api
import ./utils

export api

type KeyAuthorization* = string

type ACMEClient* = ref object
  api: ACMEApi
  key*: RsaPrivateKey
  kid*: Kid

logScope:
  topics = "libp2p acme client"

proc new*(
    T: typedesc[ACMEClient],
    rng: Rng,
    api: ACMEApi = ACMEApi.new(acmeServerURL = parseUri(LetsEncryptURL)),
    key: Opt[RsaPrivateKey] = Opt.none(RsaPrivateKey),
    kid: Kid = Kid(""),
): T {.raises: [].} =
  let key = key.valueOr:
    RsaPrivateKey.random(rng).get()
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
): Future[ACMEChallengeDns01Response] {.async: (raises: [ACMEError, CancelledError]).} =
  await self.api.requestChallenge(domains, self.key, await self.getOrInitKid())

proc getCertificate*(
    self: ACMEClient,
    domain: api.Domain,
    certKeyPair: RsaPrivateKey,
    challenge: ACMEChallengeDns01Response,
    acmeRetries: int = 10,
    finalizeRetries: int = 10,
): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let chalURL = parseUri(challenge.dns01.url)
  let orderURL = parseUri(challenge.order)
  let finalizeURL = parseUri(challenge.finalize)
  trace "Sending challenge completed notification"
  discard
    await self.api.sendChallengeCompleted(chalURL, self.key, await self.getOrInitKid())

  trace "Checking for completed challenge"
  let completed = await self.api.checkChallengeCompleted(
    chalURL, self.key, await self.getOrInitKid(), acmeRetries
  )
  if not completed:
    raise
      newException(ACMEError, "Failed to signal ACME server about challenge completion")

  trace "Waiting for certificate to be finalized"
  let finalized = await self.api.certificateFinalized(
    domain,
    finalizeURL,
    orderURL,
    certKeyPair,
    self.key,
    await self.getOrInitKid(),
    finalizeRetries,
  )
  if not finalized:
    raise newException(ACMEError, "Failed to finalize certificate for domain " & domain)

  trace "Downloading certificate"
  await self.api.downloadCertificate(orderURL)

proc close*(self: ACMEClient) {.async: (raises: [CancelledError]).} =
  await self.api.close()
