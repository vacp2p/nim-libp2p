## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../protocol,
       ../../connection

type
  Secure* = ref object of LPProtocol # base type for secure managers

method secure*(p: Secure, conn: Connection): Future[Connection]
  {.base, async, gcsafe.} =
  ## default implementation matches plaintext
  result = conn
