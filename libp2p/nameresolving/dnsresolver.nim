## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import
  std/[streams, strutils, sets, sequtils],
  chronos, chronicles,
  dnsclientpkg/[protocol, types]

import
  nameresolver

logScope:
  topics = "libp2p dnsresolver"

type
  DnsResolver* = ref object of NameResolver
    nameServers*: seq[TransportAddress]

proc questionToBuf(address: string, kind: QKind): seq[byte] =
  try:
    var
      header = initHeader()
      question = initQuestion(address, kind)

      requestStream = header.toStream()
    question.toStream(requestStream)

    let dataLen = requestStream.getPosition()
    requestStream.setPosition(0)

    var buf = newSeq[byte](dataLen)
    discard requestStream.readData(addr buf[0], dataLen)
    return buf
  except CatchableError as exc:
    info "Failed to created DNS buffer", msg = exc.msg
    return newSeq[byte](0)

proc getDnsResponse(
  dnsServer: TransportAddress,
  address: string,
  kind: QKind): Future[Response] {.async.} =

  var sendBuf = questionToBuf(address, kind)

  if sendBuf.len == 0:
    raise newException(ValueError, "Incorrect DNS query")

  let receivedDataFuture = newFuture[void]()

  proc datagramDataReceived(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.async, closure.} =
      receivedDataFuture.complete()

  let sock =
    if dnsServer.family == AddressFamily.IPv6:
      newDatagramTransport6(datagramDataReceived)
    else:
      newDatagramTransport(datagramDataReceived)

  try:
    await sock.sendTo(dnsServer, addr sendBuf[0], sendBuf.len)

    await receivedDataFuture or sleepAsync(5.seconds) #unix default

    if not receivedDataFuture.finished:
      raise newException(IOError, "DNS server timeout")

    var
      rawResponse = sock.getMessage()
      dataStream = newStringStream()
    dataStream.writeData(addr rawResponse[0], rawResponse.len)
    dataStream.setPosition(0)
    # parseResponse can has a raises: [Exception, ..] because of
    # https://github.com/nim-lang/Nim/commit/035134de429b5d99c5607c5fae912762bebb6008
    # it can't actually raise though
    return parseResponse(dataStream)
  except CatchableError as exc: raise exc
  except Exception as exc: raiseAssert exc.msg
  finally:
    await sock.closeWait()

method resolveIp*(
  self: DnsResolver,
  address: string,
  port: Port,
  domain: Domain = Domain.AF_UNSPEC): Future[seq[TransportAddress]] {.async.} =

  trace "Resolving IP using DNS", address, servers = self.nameServers.mapIt($it), domain
  for _ in 0 ..< self.nameServers.len:
    let server = self.nameServers[0]
    var responseFutures: seq[Future[Response]]
    if domain == Domain.AF_INET or domain == Domain.AF_UNSPEC:
      responseFutures.add(getDnsResponse(server, address, A))

    if domain == Domain.AF_INET6 or domain == Domain.AF_UNSPEC:
      let fut = getDnsResponse(server, address, AAAA)
      if server.family == AddressFamily.IPv6:
        trace "IPv6 DNS server, puting AAAA records first", server = $server
        responseFutures.insert(fut)
      else:
        responseFutures.add(fut)

    var
      resolvedAddresses: OrderedSet[string]
      resolveFailed = false
    for fut in responseFutures:
      try:
        let resp = await fut
        for answer in resp.answers:
          resolvedAddresses.incl(answer.toString())
      except CancelledError as e:
        raise e
      except ValueError as e:
        info "Invalid DNS query", address, error=e.msg
        return @[]
      except CatchableError as e:
        info "Failed to query DNS", address, error=e.msg
        resolveFailed = true
        break

    if resolveFailed:
      self.nameServers.add(self.nameServers[0])
      self.nameServers.delete(0)
      continue

    trace "Got IPs from DNS server", resolvedAddresses, server = $server
    return resolvedAddresses.toSeq().mapIt(initTAddress(it, port))

  debug "Failed to resolve address, returning empty set"
  return @[]

method resolveTxt*(
  self: DnsResolver,
  address: string): Future[seq[string]] {.async.} =

  trace "Resolving TXT using DNS", address, servers = self.nameServers.mapIt($it)
  for _ in 0 ..< self.nameServers.len:
    let server = self.nameServers[0]
    try:
      let response = await getDnsResponse(server, address, TXT)
      trace "Got TXT response", server = $server, answer=response.answers.mapIt(it.toString())
      return response.answers.mapIt(it.toString())
    except CancelledError as e:
      raise e
    except CatchableError as e:
      info "Failed to query DNS", address, error=e.msg
      self.nameServers.add(self.nameServers[0])
      self.nameServers.delete(0)
      continue

  debug "Failed to resolve TXT, returning empty set"
  return @[]

proc new*(
  T: typedesc[DnsResolver],
  nameServers: seq[TransportAddress]): T =
  T(nameServers: nameServers)
