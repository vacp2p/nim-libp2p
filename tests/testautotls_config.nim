{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, uri
import ../libp2p/[autotls/service, autotls/acme/api, autotls/acme/client, wire]

import ./helpers

suite "AutoTLS Configuration Tests":
  asyncTeardown:
    checkTrackers()

  asyncTest "AutotlsConfig constructor with default values":
    let config = AutotlsConfig.new()

    check:
      config.acmeServerURL == parseUri(LetsEncryptURL)
      config.renewCheckTime == DefaultRenewCheckTime
      config.renewBufferTime == DefaultRenewBufferTime
      config.brokerURL == AutoTLSBroker
      config.dnsServerURL == AutoTLSDNSServer
      config.dnsRetries == 10
      config.dnsRetryTime == 1.seconds
      config.acmeRetries == 10
      config.acmeRetryTime == 1.seconds
      config.finalizeRetries == 10
      config.finalizeRetryTime == 1.seconds

  asyncTest "AutotlsConfig constructor with custom values":
    let customBrokerURL = "custom-broker.example.com"
    let customDnsServerURL = "custom-dns.example.com"
    let customDnsRetries = 5
    let customDnsRetryTime = 2.seconds
    let customAcmeRetries = 15
    let customAcmeRetryTime = 3.seconds
    let customFinalizeRetries = 20
    let customFinalizeRetryTime = 4.seconds

    let config = AutotlsConfig.new(
      brokerURL = customBrokerURL,
      dnsServerURL = customDnsServerURL,
      dnsRetries = customDnsRetries,
      dnsRetryTime = customDnsRetryTime,
      acmeRetries = customAcmeRetries,
      acmeRetryTime = customAcmeRetryTime,
      finalizeRetries = customFinalizeRetries,
      finalizeRetryTime = customFinalizeRetryTime,
    )

    check:
      config.brokerURL == customBrokerURL
      config.dnsServerURL == customDnsServerURL
      config.dnsRetries == customDnsRetries
      config.dnsRetryTime == customDnsRetryTime
      config.acmeRetries == customAcmeRetries
      config.acmeRetryTime == customAcmeRetryTime
      config.finalizeRetries == customFinalizeRetries
      config.finalizeRetryTime == customFinalizeRetryTime

  asyncTest "AutotlsService uses custom broker URL in registration":
    let customBrokerURL = "test-broker.example.com"
    let config = AutotlsConfig.new(brokerURL = customBrokerURL)
    let service = AutotlsService.new(config = config)

    # Verify the config was stored correctly
    check service.config.brokerURL == customBrokerURL

  asyncTest "Backward compatibility with existing AutotlsConfig usage":
    # Test that existing code using AutotlsConfig.new() without new parameters still works
    let config1 = AutotlsConfig.new()
    let config2 = AutotlsConfig.new(
      acmeServerURL = parseUri(LetsEncryptURLStaging), renewCheckTime = 5.minutes
    )

    check:
      config1.acmeServerURL == parseUri(LetsEncryptURL)
      config2.acmeServerURL == parseUri(LetsEncryptURLStaging)
      config2.renewCheckTime == 5.minutes
      # New fields should have default values
      config1.brokerURL == AutoTLSBroker
      config2.brokerURL == AutoTLSBroker
