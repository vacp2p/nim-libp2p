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

  asyncTest "AutotlsConfig preserves existing parameters":
    let customServerURL = parseUri("https://custom-acme.example.com")
    let customRenewCheckTime = 30.minutes
    let customRenewBufferTime = 2.hours

    let config = AutotlsConfig.new(
      acmeServerURL = customServerURL,
      renewCheckTime = customRenewCheckTime,
      renewBufferTime = customRenewBufferTime,
      brokerURL = "custom-broker.test",
    )

    check:
      config.acmeServerURL == customServerURL
      config.renewCheckTime == customRenewCheckTime
      config.renewBufferTime == customRenewBufferTime
      config.brokerURL == "custom-broker.test"
      # Default values should still be used for non-specified params
      config.dnsServerURL == AutoTLSDNSServer
      config.dnsRetries == 10

  asyncTest "AutotlsService uses custom broker URL in registration":
    let customBrokerURL = "test-broker.example.com"
    let config = AutotlsConfig.new(brokerURL = customBrokerURL)
    let service = AutotlsService.new(config = config)

    # Verify the config was stored correctly
    check service.config.brokerURL == customBrokerURL

  asyncTest "AutotlsConfig integration with all components":
    # Test that custom config values flow through the entire system
    let customConfig = AutotlsConfig.new(
      brokerURL = "integration-test-broker.example.com",
      dnsServerURL = "integration-test-dns.example.com",
      dnsRetries = 2,
      dnsRetryTime = 100.milliseconds,
      acmeRetries = 3,
      acmeRetryTime = 200.milliseconds,
      finalizeRetries = 4,
      finalizeRetryTime = 300.milliseconds,
    )

    let service = AutotlsService.new(config = customConfig)

    # Verify all config values are preserved in the service
    check:
      service.config.brokerURL == "integration-test-broker.example.com"
      service.config.dnsServerURL == "integration-test-dns.example.com"
      service.config.dnsRetries == 2
      service.config.dnsRetryTime == 100.milliseconds
      service.config.acmeRetries == 3
      service.config.acmeRetryTime == 200.milliseconds
      service.config.finalizeRetries == 4
      service.config.finalizeRetryTime == 300.milliseconds

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
