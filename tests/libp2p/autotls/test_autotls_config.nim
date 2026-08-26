# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, net, uri
import
  ../../../libp2p/[
    autotls/service,
    autotls/acme/api,
    autotls/acme/client,
    nameresolving/dnsresolver,
    wire,
  ]
import ../../tools/[unittest, crypto]

suite "AutoTLS Configuration Tests":
  asyncTeardown:
    checkTrackers()

  asyncTest "AutotlsConfig constructor with default values":
    let config = AutotlsConfig.new()

    check:
      config.acmeServerURL == parseUri(LetsEncryptURL)
      config.ipAddress == Opt.none(IpAddress)
      config.renewCheckTime == DefaultRenewCheckTime
      config.renewBufferTime == DefaultRenewBufferTime
      config.issueRetries == 3
      config.issueRetryTime == 1.seconds
      config.brokerURL == DefaultBrokerURL
      config.dnsServerURL == AutoTLSDNSServer
      config.dnsRetries == 10
      config.dnsRetryTime == 1.seconds
      config.acmeRetries == 10
      config.acmeRetryTime == 1.seconds
      config.finalizeRetries == 10
      config.finalizeRetryTime == 1.seconds

  asyncTest "AutotlsConfig constructor with custom values":
    let customIpAddress = parseIpAddress("203.0.113.7")
    let customNameServers =
      @[initTAddress("192.0.2.53:53"), initTAddress("198.51.100.53:53")]
    let customRenewCheckTime = 7.minutes
    let customRenewBufferTime = 8.minutes
    let customIssueRetries = 7
    let customIssueRetryTime = 5.seconds
    let customBrokerURL = "custom-broker.example.com"
    let customDnsServerURL = "custom-dns.example.com"
    let customDnsRetries = 5
    let customDnsRetryTime = 2.seconds
    let customAcmeRetries = 15
    let customAcmeRetryTime = 3.seconds
    let customFinalizeRetries = 20
    let customFinalizeRetryTime = 4.seconds

    let config = AutotlsConfig.new(
      ipAddress = Opt.some(customIpAddress),
      nameServers = customNameServers,
      renewCheckTime = customRenewCheckTime,
      renewBufferTime = customRenewBufferTime,
      issueRetries = customIssueRetries,
      issueRetryTime = customIssueRetryTime,
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
      config.ipAddress == Opt.some(customIpAddress)
      # nameServers reaches the config as the DnsResolver built out of it.
      DnsResolver(config.nameResolver).nameServers == customNameServers
      config.renewCheckTime == customRenewCheckTime
      config.renewBufferTime == customRenewBufferTime
      config.issueRetries == customIssueRetries
      config.issueRetryTime == customIssueRetryTime
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
    let service = AutotlsService.new(rng(), config = config)

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
      config1.brokerURL == DefaultBrokerURL
      config2.brokerURL == DefaultBrokerURL
