# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, json, net, sequtils, uri
from times import now, initDuration, `+`
import
  ../../../libp2p/
    [autotls/service, autotls/broker, autotls/acme/client, crypto/rsa, switch, wire]
import
  ../../tools/[unittest, crypto, multiaddress, resolver, stall_server, switch_builder]
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
  var authClient {.threadvar.}: PeerIDAuthClientStub
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
      broker: AutotlsBroker.new(rng(), DefaultBrokerURL, authClient),
      cert: Opt.none(AutotlsCert),
      certReady: newAsyncEvent(),
      running: newAsyncEvent(),
      config: config,
      rng: rng(),
    )

  proc installCert(service: AutotlsService, expiresIn: times.Duration) =
    service.cert = Opt.some(AutotlsCert.new(cert, certKey, now() + expiresIn))
    service.certReady.fire()

  asyncSetup:
    acmeApi = ACMEApiStub.new()
    authClient = PeerIDAuthClientStub.new()
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
    # renewCheckTime is left at its 1 hour default, so a second round won't start
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

  asyncTest "the certificate is handed over once issuance fires":
    service = newService()

    let certFut = service.getCertWhenReady()
    check not certFut.finished

    service.installCert(initDuration(hours = 2))

    let autotlsCert = await certFut.wait(1.seconds)
    check:
      autotlsCert.cert == cert
      autotlsCert.privkey == certKey

  asyncTest "the certificate in place is handed over while its renewal is in flight":
    acmeApi.stalls = true
    service = newService()
    service.installCert(initDuration(minutes = 5))
    await service.start(switch)

    check acmeApi.requestedUris.len == 1

    let autotlsCert = await service.getCertWhenReady().wait(1.seconds)
    check autotlsCert.cert == cert

  asyncTest "the broker is sent the addresses the peer announces":
    const
      NodeIP = "127.0.0.1"
      AnnouncedAddrs =
        ["/ip4/" & NodeIP & "/tcp/9000", "/ip4/" & NodeIP & "/tcp/9001/ws"]
    switch.peerInfo.announcedAddrs = AnnouncedAddrs.mapIt(ma(it))

    acmeApi.scriptChallenge("some-token")

    var config = AutotlsConfig.new(
      ipAddress = Opt.some(parseIpAddress(NodeIP)), issueRetries = 0, dnsRetries = 0
    )
    config.nameResolver = StubNameResolver.new()
    service = newService(config)
    await service.start(switch)

    check parseJson(authClient.payloads[0])["addresses"] == %AnnouncedAddrs

suite "AutoTLS on a switch":
  asyncTeardown:
    checkTrackers()

  asyncTest "no ACME request is made, the service starts before its transports":
    # TODO: vacp2p/nim-libp2p#2957
    # The service never begins issuance: no TcpTransport is running when it starts.
    let acmeServer = startStallServer()
    defer:
      await acmeServer.stop()

    let switch = makeStandardSwitchBuilder(
        @[TcpAutoAddress, ma("/ip4/127.0.0.1/tcp/0/wss")]
      )
      .withAutotls(
        AutotlsConfig.new(
          ipAddress = Opt.some(parseIpAddress("127.0.0.1")),
          acmeServerURL =
            parseUri("http://" & $acmeServer.address.initTAddress().tryGet()),
        )
      )
      .build()
    defer:
      await switch.stop()

    let startFut = switch.start()
    defer:
      await startFut.cancelAndWait()

    # Issuance would connect to acmeServerURL, so no connection means no attempt.
    check not (await acmeServer.waitAccepted().withTimeout(200.milliseconds))

  asyncTest "a switch listening on wss never finishes starting without a certificate":
    # TODO: vacp2p/nim-libp2p#2957
    # The transport waits for a certificate with no timeout, so start never returns.
    let switch = makeStandardSwitchBuilder(
        @[TcpAutoAddress, ma("/ip4/127.0.0.1/tcp/0/wss")]
      )
      .withAutotls(
        AutotlsConfig.new(
          ipAddress = Opt.some(parseIpAddress("127.0.0.1")),
          # A refused connection fails issuance at once, leaving the certificate
          # wait as the only thing that can hang.
          acmeServerURL = parseUri("http://127.0.0.1:1"),
        )
      )
      .build()
    defer:
      await switch.stop()

    let startFut = switch.start()
    check not (await startFut.withTimeout(500.milliseconds))
