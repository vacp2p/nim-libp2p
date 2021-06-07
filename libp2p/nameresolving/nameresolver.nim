## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import chronos

type 
  NameResolver* = ref object of RootObj

method resolveTxt*(
  self: NameResolver,
  address: string): Future[seq[string]] {.async, base.} =
  ## Get TXT record
  ## 

  doAssert(false, "Not implemented!")

method resolveIp*(
  self: NameResolver,
  address: string,
  port: Port,
  domain: Domain = Domain.AF_UNSPEC): Future[seq[TransportAddress]] {.async, base.} =
  ## Resolve the specified address
  ## 

  doAssert(false, "Not implemented!")
