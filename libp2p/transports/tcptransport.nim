# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## TCP transport implementation

{.push raises: [].}

import std/[sequtils]
import chronos, chronicles
import
  ./transport,
  ../wire,
  ../multiaddress,
  ../stream/connection,
  ../stream/chronosstream,
  ../upgrademngrs/upgrade,
  ../utility

logScope:
  topics = "libp2p tcptransport"

export transport, connection, upgrade

const TcpTransportTrackerName* = "libp2p.tcptransport"

type
  AcceptFuture = typeof(default(StreamServer).accept())

  TcpTransport* = ref object of Transport
    servers*: seq[StreamServer]
    clients: array[Direction, seq[StreamTransport]]
    flags: set[ServerFlags]
    clientFlags: set[SocketFlags]
    acceptFuts: seq[AcceptFuture]
    connectionsTimeout: Duration
    stopping: bool

  TcpTransportError* = object of transport.TransportError

proc connHandler*(
    self: TcpTransport,
    client: StreamTransport,
    observedAddr: Opt[MultiAddress],
    dir: Direction,
): Connection =
  trace "Handling tcp connection",
    address = $observedAddr,
    dir = $dir,
    clients = self.clients[Direction.In].len + self.clients[Direction.Out].len

  let conn = Connection(
    ChronosStream.init(
      client = client,
      dir = dir,
      observedAddr = observedAddr,
      timeout = self.connectionsTimeout,
    )
  )

  proc onClose() {.async: (raises: []).} =
    await noCancel client.join()

    trace "Cleaning up client", addrs = $client.remoteAddress, conn

    self.clients[dir].keepItIf(it != client)

    # Propagate the chronos client being closed to the connection
    # TODO This is somewhat dubious since it's the connection that owns the
    #      client, but it allows the transport to close all connections when
    #      shutting down (also dubious! it would make more sense that the owner
    #      of all connections closes them, or the next read detects the closed
    #      socket and does the right thing..)

    await conn.close()

    trace "Cleaned up client", addrs = $client.remoteAddress, conn

  self.clients[dir].add(client)

  asyncSpawn onClose()

  return conn

proc new*(
    T: typedesc[TcpTransport],
    flags: set[ServerFlags] = {},
    upgrade: Upgrade,
    connectionsTimeout = 10.minutes,
): T {.public.} =
  T(
    flags: flags,
    clientFlags:
      if ServerFlags.TcpNoDelay in flags:
        {SocketFlags.TcpNoDelay}
      else:
        default(set[SocketFlags])
    ,
    upgrader: upgrade,
    networkReachability: NetworkReachability.Unknown,
    connectionsTimeout: connectionsTimeout,
  )

method start*(self: TcpTransport, addrs: seq[MultiAddress]): Future[void] =
  ## Start transport listening to the given addresses - for dial-only transports,
  ## start with an empty list

  # TODO remove `impl` indirection throughout when `raises` is added to base

  proc impl(
      self: TcpTransport, addrs: seq[MultiAddress]
  ): Future[void] {.async: (raises: [transport.TransportError, CancelledError]).} =
    if self.running:
      warn "TCP transport already running"
      return

    trace "Starting TCP transport"

    self.flags.incl(ServerFlags.ReusePort)

    var supported: seq[MultiAddress]
    var initialized = false
    try:
      for i, ma in addrs:
        if not self.handles(ma):
          trace "Invalid address detected, skipping!", address = ma
          continue

        let
          ta = initTAddress(ma).expect("valid address per handles check above")
          server =
            try:
              createStreamServer(ta, flags = self.flags)
            except common.TransportError as exc:
              raise (ref TcpTransportError)(msg: exc.msg, parent: exc)

        self.servers &= server

        trace "Listening on", address = ma
        supported.add(
          MultiAddress.init(server.sock.getLocalAddress()).expect(
            "Can init from local address"
          )
        )

      initialized = true
    finally:
      if not initialized:
        # Clean up partial success on exception
        await noCancel allFutures(self.servers.mapIt(it.closeWait()))
        reset(self.servers)

    try:
      await procCall Transport(self).start(supported)
    except CatchableError:
      raiseAssert "Base method does not raise"

    trackCounter(TcpTransportTrackerName)

  impl(self, addrs)

method stop*(self: TcpTransport): Future[void] =
  ## Stop the transport and close all connections it created
  proc impl(self: TcpTransport) {.async: (raises: []).} =
    trace "Stopping TCP transport"
    self.stopping = true
    defer:
      self.stopping = false

    if self.running:
      # Reset the running flag
      try:
        await noCancel procCall Transport(self).stop()
      except CatchableError: # TODO remove when `accept` is annotated with raises
        raiseAssert "doesn't actually raise"

      # Stop each server by closing the socket - this will cause all accept loops
      # to fail - since the running flag has been reset, it's also safe to close
      # all known clients since no more of them will be added
      await noCancel allFutures(
        self.servers.mapIt(it.closeWait()) &
          self.clients[Direction.In].mapIt(it.closeWait()) &
          self.clients[Direction.Out].mapIt(it.closeWait())
      )

      self.servers = @[]

      for acceptFut in self.acceptFuts:
        if acceptFut.completed():
          await acceptFut.value().closeWait()
      self.acceptFuts = @[]

      if self.clients[Direction.In].len != 0 or self.clients[Direction.Out].len != 0:
        # Future updates could consider turning this warn into an assert since
        # it should never happen if the shutdown code is correct
        warn "Couldn't clean up clients",
          len = self.clients[Direction.In].len + self.clients[Direction.Out].len

      trace "Transport stopped"
      untrackCounter(TcpTransportTrackerName)
    else:
      # For legacy reasons, `stop` on a transpart that wasn't started is
      # expected to close outgoing connections created by the transport
      warn "TCP transport already stopped"

      doAssert self.clients[Direction.In].len == 0,
        "No incoming connections possible without start"
      await noCancel allFutures(self.clients[Direction.Out].mapIt(it.closeWait()))

  impl(self)

method accept*(self: TcpTransport): Future[Connection] =
  ## accept a new TCP connection, returning nil on non-fatal errors
  ##
  ## Raises an exception when the transport is broken and cannot be used for
  ## accepting further connections
  # TODO returning nil for non-fatal errors is problematic in that error
  #      information is lost and must be logged here instead of being
  #      available to the caller - further refactoring should propagate errors
  #      to the caller instead
  proc impl(
      self: TcpTransport
  ): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
    if not self.running:
      raise newTransportClosedError()

    if self.acceptFuts.len <= 0:
      # Holds futures representing ongoing accept calls on multiple servers.
      self.acceptFuts = self.servers.mapIt(it.accept())

    let
      finished =
        try:
          # Waits for any one of these futures to complete, indicating that a new connection has been accepted on one of the servers.
          await one(self.acceptFuts)
        except ValueError:
          raise (ref TcpTransportError)(msg: "No listeners configured")
      index = self.acceptFuts.find(finished)

    # A new connection has been accepted. The corresponding server should immediately start accepting another connection.
    # Thus we replace the completed future with a new one by calling accept on the same server again.
    self.acceptFuts[index] = self.servers[index].accept()
    let transp =
      try:
        await finished
      except TransportTooManyError as exc:
        debug "Too many files opened", exc = exc.msg
        return nil
      except TransportAbortedError as exc:
        debug "Connection aborted", exc = exc.msg
        return nil
      except TransportUseClosedError as exc:
        raise newTransportClosedError(exc)
      except TransportOsError as exc:
        raise (ref TcpTransportError)(msg: exc.msg, parent: exc)
      except common.TransportError as exc: # Needed for chronos 4.0.0 support
        raise (ref TcpTransportError)(msg: exc.msg, parent: exc)
      except CancelledError as exc:
        raise exc

    if not self.running: # Stopped while waiting
      await transp.closeWait()
      raise newTransportClosedError()

    let remote =
      try:
        transp.remoteAddress
      except TransportOsError as exc:
        # The connection had errors / was closed before `await` returned control
        await transp.closeWait()
        debug "Cannot read remote address", exc = exc.msg
        return nil

    let observedAddr =
      MultiAddress.init(remote).expect("Can initialize from remote address")
    self.connHandler(transp, Opt.some(observedAddr), Direction.In)

  impl(self)

method dial*(
    self: TcpTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] =
  ## dial a peer
  proc impl(
      self: TcpTransport, hostname: string, address: MultiAddress, peerId: Opt[PeerId]
  ): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
    if self.stopping:
      raise newTransportClosedError()

    let ta = initTAddress(address).valueOr:
      raise (ref TcpTransportError)(msg: "Unsupported address: " & $address)

    trace "Dialing remote peer", address = $address
    let transp =
      try:
        await(
          if self.networkReachability == NetworkReachability.NotReachable and
              self.addrs.len > 0:
            let local = initTAddress(self.addrs[0]).expect("self address is valid")
            self.clientFlags.incl(SocketFlags.ReusePort)
            connect(ta, flags = self.clientFlags, localAddress = local)
          else:
            connect(ta, flags = self.clientFlags)
        )
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        raise (ref TcpTransportError)(msg: exc.msg, parent: exc)

    # If `stop` is called after `connect` but before `await` returns, we might
    # end up with a race condition where `stop` returns but not all connections
    # have been closed - we drop connections in this case in order not to leak
    # them
    if self.stopping:
      # Stopped while waiting for new connection
      await transp.closeWait()
      raise newTransportClosedError()

    let observedAddr =
      try:
        MultiAddress.init(transp.remoteAddress).expect("remote address is valid")
      except TransportOsError as exc:
        await transp.closeWait()
        raise (ref TcpTransportError)(msg: exc.msg)

    self.connHandler(transp, Opt.some(observedAddr), Direction.Out)

  impl(self, hostname, address, peerId)

method handles*(t: TcpTransport, address: MultiAddress): bool =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return TCP.match(address)
