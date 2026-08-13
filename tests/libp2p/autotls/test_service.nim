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

suite "AutoTLS certificate renewal":
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

  proc newService(): AutotlsService =
    AutotlsService(
      acmeClient:
        ACMEClient.new(rng(), api = ACMEApi(acmeApi), key = Opt.some(accountKey)),
      broker: AutotlsBroker.new(rng(), DefaultBrokerURL, PeerIDAuthClientStub.new()),
      cert: Opt.none(AutotlsCert),
      certReady: newAsyncEvent(),
      running: newAsyncEvent(),
      config: AutotlsConfig.new(
        renewCheckTime = RenewCheckTime, renewBufferTime = RenewBufferTime
      ),
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
    checkUntilTimeoutCustom(5.seconds, 10.milliseconds):
      acmeApi.requestedUris.len > 0

  asyncTest "a certificate expiring in 90 minutes is not renewed under a 1 hour buffer":
    service = newService()
    service.installCert(initDuration(minutes = 90))
    await service.start(switch)

    # Nothing signals a heartbeat that decided against renewing, so wait out several.
    await sleepAsync(10 * RenewCheckTime)

    check acmeApi.requestedUris.len == 0
