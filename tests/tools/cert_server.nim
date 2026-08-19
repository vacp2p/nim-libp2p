# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronicles, chronos
import websock/http/[common, server]

type CertServer* = ref object
  ## Serves one certificate over plain HTTP.
  ## `downloadCertificate` fetches the order's certificate URL through the session,
  ## so it is the one ACME request a stub cannot answer.
  server: HttpServer
  url*: string

proc startCertServer*(certificate: string): CertServer =
  proc serve(request: HttpRequest) {.async.} =
    await request.sendResponse(Http200, data = certificate)

  let server = HttpServer.create(initTAddress("127.0.0.1:0"), serve, {ReuseAddr})
  server.start()

  # `local` carries the address the socket really bound, port 0 resolved.
  CertServer(server: server, url: "http://" & $server.local & "/certificate")

proc stop*(cert: CertServer) {.async: (raises: [TransportOsError]).} =
  cert.server.stop()
  await cert.server.closeWait()
