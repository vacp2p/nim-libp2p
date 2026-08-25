# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronicles, chronos
import websock/http/[common, server]

type TestHttpServer* = ref object
  ## Answers every request with one fixed body over plain HTTP.
  server: HttpServer
  url*: string

proc startTestHttpServer*(body: string): TestHttpServer =
  proc serve(request: HttpRequest) {.async.} =
    await request.sendResponse(Http200, data = body)

  let server = HttpServer.create(initTAddress("127.0.0.1:0"), serve, {ReuseAddr})
  server.start()

  # `local` carries the address the socket really bound, port 0 resolved.
  TestHttpServer(server: server, url: "http://" & $server.local & "/")

proc stop*(self: TestHttpServer) {.async: (raises: [TransportOsError]).} =
  self.server.stop()
  await self.server.closeWait()
