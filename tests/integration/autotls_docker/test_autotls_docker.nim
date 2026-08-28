# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import net, uri
from times import now, `<`
import chronos, chronos/apps/http/httpclient
import
  ../../../libp2p/
    [autotls/acme/api, autotls/acme/client, autotls/broker, autotls/service, switch]
import ../../tools/[unittest, crypto, multiaddress, switch_builder]

const
  PebbleDirectoryURL = "https://127.0.0.1/dir"
  ForgeRegistrationURL = "http://127.0.0.1:5380/v1/_acme-challenge"
  ForgeNameServer = "127.0.0.1:5354"
  NodeIP = "127.0.0.1"
  RenewCheckTime = 1.seconds
  IssueTimeout = 60.seconds

suite "AutoTLS against a local ACME server and broker":
  asyncTeardown:
    checkTrackers()

  asyncTest "a certificate is issued end to end":
    # TODO: vacp2p/nim-libp2p#2957
    let switch = makeStandardSwitchBuilder(TcpAutoAddress).withYamux().build()
    await switch.start()
    defer:
      await switch.stop()

    let service = AutotlsService(
      acmeClient: ACMEClient.new(
        rng(),
        api = ACMEApi.new(
          directoryURL = parseUri(PebbleDirectoryURL),
          # Pebble presents a self-signed certificate and chronos cannot be handed a
          # trust anchor.
          flags = {HttpClientFlag.NoVerifyHost, HttpClientFlag.NoVerifyServerName},
        ),
      ),
      broker: AutotlsBroker.new(rng(), registrationURL = parseUri(ForgeRegistrationURL)),
      cert: Opt.none(AutotlsCert),
      certReady: newAsyncEvent(),
      running: newAsyncEvent(),
      config: AutotlsConfig.new(
        ipAddress = Opt.some(parseIpAddress(NodeIP)),
        nameServers = @[initTAddress(ForgeNameServer)],
        renewCheckTime = RenewCheckTime,
      ),
      rng: rng(),
    )
    await service.start(switch)
    defer:
      await service.stop(switch)

    let cert = await service.getCertWhenReady().wait(IssueTimeout)
    check cert.expiry > now()
