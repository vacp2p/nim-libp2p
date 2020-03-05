## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import typetraits
import chronos
import chronicles
import ../protocol,
       ../../connection,
       ../../stream/bufferstream

logScope:
  topic = "secure"

type
  Secure* = ref object of LPProtocol # base type for secure managers
  SecureConnection* = ref object of Connection

method secure*(p: Secure, conn: Connection; outgoing: bool): Future[Connection] {.base.} =
  ## default implementation matches plaintext
  var retFuture = newFuture[Connection]("secure.secure")
  retFuture.complete(conn)
  return retFuture
