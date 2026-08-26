# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import json, uri
import chronos
import ../../../libp2p/crypto/rsa
import ../../../libp2p/autotls/acme/[api, utils]
import ../../tools/[unittest, http_server]
import ./rfc_vectors

suite "ACME utils":
  asyncTeardown:
    checkTrackers()

  test "base64url uses the URL-safe alphabet and drops the padding":
    check:
      # Standard base64 renders these three bytes as "+/+/".
      base64UrlEncode(@[byte 0xFB, 0xFF, 0xBF]) == "-_-_"
      # One input per length residue, so both "=" and "==" have to go.
      base64UrlEncode(@[byte 1]) == "AQ"
      base64UrlEncode(@[byte 1, 2]) == "AQI"
      base64UrlEncode(@[byte 1, 2, 3]) == "AQID"

  test "the fixture is a valid RSA key":
    let key = rfc7517Key()
    check rsa.verify(key.sign("probe").expect("sign"), "probe", key.getPublicKey())

  test "the thumbprint is the RFC 7638 canonical form":
    check thumbprint(rfc7517Key()) == Rfc7638Thumbprint

  asyncTest "an empty response body reads as an empty object":
    # The response to `newNonce` carries the nonce in a header and no body at all.
    let server = startTestHttpServer("")
    defer:
      await server.stop()
    let acmeApi = ACMEApi.new()
    defer:
      await acmeApi.close()

    check (await acmeApi.get(parseUri(server.url))).body == %*{}

  asyncTest "a response body that is not JSON is refused":
    let server = startTestHttpServer("<html>not json</html>")
    defer:
      await server.stop()
    let acmeApi = ACMEApi.new()
    defer:
      await acmeApi.close()

    expect(ACMEError):
      discard await acmeApi.get(parseUri(server.url))
