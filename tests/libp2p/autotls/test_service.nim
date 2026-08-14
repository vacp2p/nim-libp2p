# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
from times import now, initDuration, `+`
import
  ../../../libp2p/
    [autotls/service, autotls/broker, autotls/acme/client, crypto/rsa, switch]
import ../../tools/[unittest, crypto, multiaddress, switch_builder]
import ../../stubs/[acme_api_stub, peer_id_auth_client_stub]

suite "AutoTLS certificate issuance and renewal":
  const
    RenewCheckTime = 20.milliseconds
    RenewBufferTime = 1.hours

  # RSA generation dominates the runtime of every test here, so one key pair each.
  let
    accountKey = RsaPrivateKey.random(rng()).get()
    (certKey, cert) = tlsCertGenerator()

  var acmeApi {.threadvar.}: ACMEApiStub
  var service {.threadvar.}: AutotlsService
  var switch {.threadvar.}: Switch

  proc newService(
      config: AutotlsConfig = AutotlsConfig.new(
        renewCheckTime = RenewCheckTime, renewBufferTime = RenewBufferTime
      )
  ): AutotlsService =
    AutotlsService(
      acmeClient:
        ACMEClient.new(rng(), api = ACMEApi(acmeApi), key = Opt.some(accountKey)),
      broker: AutotlsBroker.new(rng(), DefaultBrokerURL, PeerIDAuthClientStub.new()),
      cert: Opt.none(AutotlsCert),
      certReady: newAsyncEvent(),
      running: newAsyncEvent(),
      config: config,
      rng: rng(),
    )

  proc installCert(service: AutotlsService, expiresIn: times.Duration) =
    service.cert = Opt.some(AutotlsCert.new(cert, certKey, now() + expiresIn))

  asyncSetup:
    acmeApi = ACMEApiStub.new()
    switch = makeStandardSwitch(TcpAutoAddress)
    await switch.start()

  asyncTeardown:
    await service.stop(switch)
    await switch.stop()
    checkTrackers()

  asyncTest "a certificate expiring in 5 minutes is renewed":
    service = newService()
    service.installCert(initDuration(minutes = 5))
    await service.start(switch)

    # A renewal attempt fails on its first ACME request, which is enough to see it.
    checkUntilTimeout:
      acmeApi.requestedUris.len > 0

  asyncTest "a certificate expiring in 90 minutes is not renewed under a 1 hour buffer":
    service = newService()
    service.installCert(initDuration(minutes = 90))
    await service.start(switch)

    # Nothing signals a heartbeat that decided against renewing, so wait out several.
    await sleepAsync(10 * RenewCheckTime)

    check acmeApi.requestedUris.len == 0

  asyncTest "issuance is retried issueRetries times":
    # The default renew check time keeps the run to a single round.
    service =
      newService(AutotlsConfig.new(issueRetries = 3, issueRetryTime = 0.seconds))
    await service.start(switch)

    # Every attempt fails on its first ACME request, so a request is an attempt.
    checkUntilTimeout:
      acmeApi.requestedUris.len == 4

  asyncTest "a failed round is retried on the next heartbeat":
    # No retries, so a round is one request.
    service =
      newService(AutotlsConfig.new(issueRetries = 0, renewCheckTime = RenewCheckTime))
    await service.start(switch)

    checkUntilTimeout:
      acmeApi.requestedUris.len >= 2

  asyncTest "a service stopped during issuance makes no further attempt":
    acmeApi.stalls = true
    service = newService(AutotlsConfig.new(issueRetries = 3))
    await service.start(switch)

    check acmeApi.requestedUris.len == 1

    await service.stop(switch).wait(1.seconds)

    check acmeApi.requestedUris.len == 1
