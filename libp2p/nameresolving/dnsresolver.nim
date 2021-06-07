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
  streams,
  chronos,
  private/[protocol, records, types] #dnsclient

import
  nameresolver

type
  DnsResolver* = ref object of NameResolver

proc questionToBuf(address: string, kind: QKind): seq[byte] =
  try:
    var
      header = initHeader()
      question = initQuestion(address, A)

      requestStream = header.toStream()
    question.toStream(requestStream)

    let dataLen = requestStream.getPosition()
    requestStream.setPosition(0)

    var buf = newSeq[byte](dataLen)
    discard requestStream.readData(addr buf[0], dataLen)
    return buf
  except IOError, ValueError, OSError:
    return newSeq[byte](0)

proc getDnsResponse(
  dnsServer: TransportAddress,
  address: string,
  kind: QKind): Future[Response] {.async.} =
  let receivedDataFuture = newFuture[void]()

  proc datagramDataReceived(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.async, closure.} =
      receivedDataFuture.complete()

  let sock = newDatagramTransport(datagramDataReceived)

  var sendBuf = questionToBuf(address, A)

  await sock.sendTo(dnsServer, addr sendBuf[0], sendBuf.len)
  await receivedDataFuture

  var
    rawResponse = sock.getMessage()
    dataStream = newStringStream()
  dataStream.writeData(addr rawResponse[0], rawResponse.len)
  dataStream.setPosition(0)
  return parseResponse(dataStream)


method resolveIp*(
  self: DnsResolver,
  address: string,
  port: Port,
  domain: Domain = Domain.AF_UNSPEC): Future[seq[TransportAddress]] {.async.} =

  let
    sendBuf = await getDnsResponse(initTAddress("8.8.8.8:53"), address, A)

dumpRR(waitFor(getDnsResponse(initTAddress("192.168.1.1:53"), "google.fr", A)).answers)
