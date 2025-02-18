## # Tron example
##
## In this tutorial, we will create a video game based on libp2p, using
## all of the features we talked about in the last tutorials.
##
## We will:
## - Discover peers using the Discovery Manager
## - Use GossipSub to find a play mate
## - Create a custom protocol to play with him
##
## While this may look like a daunting project, it's less than 150 lines of code.
##
## The game will be a simple Tron. We will use [nico](https://github.com/ftsf/nico)
## as a game engine. (you need to run `nimble install nico` to have it available)
##
## ![multiplay](https://user-images.githubusercontent.com/13471753/198852714-b55048e3-f233-4723-900d-2193ad259fe1.gif)
##
## We will start by importing our dependencies and creating our types
import os
import nico, chronos, stew/byteutils, stew/endians2
import libp2p
import libp2p/protocols/rendezvous
import libp2p/discovery/rendezvousinterface
import libp2p/discovery/discoverymngr

const
  directions = @[(K_UP, 0, -1), (K_LEFT, -1, 0), (K_DOWN, 0, 1), (K_RIGHT, 1, 0)]
  mapSize = 32
  tickPeriod = 0.2

type
  Player = ref object
    x, y: int
    currentDir, nextDir: int
    lost: bool
    color: int

  Game = ref object
    gameMap: array[mapSize * mapSize, int]
    tickTime: float
    localPlayer, remotePlayer: Player
    peerFound: Future[Connection]
    hasCandidate: bool
    tickFinished: Future[int]

  GameProto = ref object of LPProtocol

proc new(_: type[Game]): Game =
  # Default state of a game
  result = Game(
    tickTime: -3.0, # 3 seconds of "warm-up" time
    localPlayer: Player(x: 4, y: 16, currentDir: 3, nextDir: 3, color: 8),
    remotePlayer: Player(x: 27, y: 16, currentDir: 1, nextDir: 1, color: 12),
    peerFound: newFuture[Connection](),
  )
  for pos in 0 .. result.gameMap.high:
    if pos mod mapSize in [0, mapSize - 1] or pos div mapSize in [0, mapSize - 1]:
      result.gameMap[pos] = 7

## ## Game Logic
## The networking during the game will work like this:
##
## * Each player will have `tickPeriod` (0.1) seconds to choose
##   a direction that he wants to go to (default to current direction)
## * After `tickPeriod`, we will send our choosen direction to the peer,
##   and wait for his direction
## * Once we have both direction, we will "tick" the game, and restart the
##   loop, as long as both player are alive.
##
## This is a very simplistic scheme, but creating proper networking for
## video games is an [art](https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization)
##
## The main drawback of this scheme is that the more ping you have with
## the peer, the slower the game will run. Or invertedly, the less ping you
## have, the faster it runs!
proc update(g: Game, dt: float32) =
  # Will be called at each frame of the game.
  #
  # Because both Nico and Chronos have a main loop,
  # they must share the control of the main thread.
  # This is a hacky way to make this happen
  waitFor(sleepAsync(1.milliseconds))
  # Don't do anything if we are still waiting for an opponent
  if not (g.peerFound.finished()) or isNil(g.tickFinished):
    return
  g.tickTime += dt

  # Update the wanted direction, making sure we can't go backward
  for i in 0 .. directions.high:
    if i != (g.localPlayer.currentDir + 2 mod 4) and keyp(directions[i][0]):
      g.localPlayer.nextDir = i

  if g.tickTime > tickPeriod and not g.tickFinished.finished():
    # We choosen our next direction, let the networking know
    g.localPlayer.currentDir = g.localPlayer.nextDir
    g.tickFinished.complete(g.localPlayer.currentDir)

proc tick(g: Game, p: Player) =
  # Move player and check if he lost
  p.x += directions[p.currentDir][1]
  p.y += directions[p.currentDir][2]
  if g.gameMap[p.y * mapSize + p.x] != 0:
    p.lost = true
  g.gameMap[p.y * mapSize + p.x] = p.color

proc mainLoop(g: Game, peer: Connection) {.async.} =
  while not (g.localPlayer.lost or g.remotePlayer.lost):
    if g.tickTime > 0.0:
      g.tickTime = 0
    g.tickFinished = newFuture[int]()

    # Wait for a choosen direction
    let dir = await g.tickFinished
    # Send it
    await peer.writeLp(toBytes(uint32(dir)))

    # Get the one from the peer
    g.remotePlayer.currentDir = int uint32.fromBytes(await peer.readLp(8))
    # Tick the players & restart
    g.tick(g.remotePlayer)
    g.tick(g.localPlayer)

## We'll draw the map & put some texts when necessary:
proc draw(g: Game) =
  for pos, color in g.gameMap:
    setColor(color)
    boxFill(pos mod 32 * 4, pos div 32 * 4, 4, 4)
  let text =
    if not (g.peerFound.finished()):
      "Matchmaking.."
    elif g.tickTime < -1.5:
      "Welcome to Etron"
    elif g.tickTime < 0.0:
      "- " & $(int(abs(g.tickTime) / 0.5) + 1) & " -"
    elif g.remotePlayer.lost and g.localPlayer.lost:
      "DEUCE"
    elif g.localPlayer.lost:
      "YOU LOOSE"
    elif g.remotePlayer.lost:
      "YOU WON"
    else:
      ""
  printc(text, screenWidth div 2, screenHeight div 2)

## ## Matchmaking
## To find an opponent, we will broadcast our address on a
## GossipSub topic, and wait for someone to connect to us.
## We will also listen to that topic, and connect to anyone
## broadcasting his address.
##
## If we are looking for a game, we'll send `ok` to let the
## peer know that we are available, check that he is also available,
## and launch the game.
proc new(T: typedesc[GameProto], g: Game): T =
  proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
    defer:
      await conn.closeWithEof()
    try:
      if g.peerFound.finished or g.hasCandidate:
        await conn.close()
        return
      g.hasCandidate = true
      await conn.writeLp("ok")
      if "ok" != string.fromBytes(await conn.readLp(1024)):
        g.hasCandidate = false
        return
      g.peerFound.complete(conn)
      # The handler of a protocol must wait for the stream to
      # be finished before returning
      await conn.join()
    except:
       echo "exception in handler", getCurrentException().msg

  return T.new(codecs = @["/tron/1.0.0"], handler = handle)

proc networking(g: Game) {.async.} =
  # Create our switch, similar to the GossipSub example and
  # the Discovery examples combined
  let
    rdv = RendezVous.new()
    switch = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
      .withTcpTransport()
      .withYamux()
      .withNoise()
      .withRendezVous(rdv)
      .build()
    dm = DiscoveryManager()
    gameProto = GameProto.new(g)
    gossip = GossipSub.init(switch = switch, triggerSelf = false)
  dm.add(RendezVousInterface.new(rdv))

  switch.mount(gossip)
  switch.mount(gameProto)

  gossip.subscribe(
    "/tron/matchmaking",
    proc(topic: string, data: seq[byte]) {.async.} =
      # If we are still looking for an opponent,
      # try to match anyone broadcasting its address
      if g.peerFound.finished or g.hasCandidate:
        return
      g.hasCandidate = true

      try:
        let
          (peerId, multiAddress) = parseFullAddress(data).tryGet()
          stream = await switch.dial(peerId, @[multiAddress], gameProto.codec)

        await stream.writeLp("ok")
        if (await stream.readLp(10)) != "ok".toBytes:
          g.hasCandidate = false
          return
        g.peerFound.complete(stream)
        # We are "player 2"
        swap(g.localPlayer, g.remotePlayer)
      except CatchableError as exc:
        discard,
  )

  await switch.start()
  defer:
    await switch.stop()

  # As explained in the last tutorial, we need a bootnode to be able
  # to find peers. We could use any libp2p running rendezvous (or any
  # node running tron). We will take it's MultiAddress from the command
  # line parameters
  if paramCount() > 0:
    let (peerId, multiAddress) = paramStr(1).parseFullAddress().tryGet()
    await switch.connect(peerId, @[multiAddress])
  else:
    echo "No bootnode provided, listening on: ", switch.peerInfo.fullAddrs.tryGet()

  # Discover peers from the bootnode, and connect to them
  dm.advertise(RdvNamespace("tron"))
  let discoveryQuery = dm.request(RdvNamespace("tron"))
  discoveryQuery.forEach:
    try:
      await switch.connect(peer[PeerId], peer.getAll(MultiAddress))
    except CatchableError as exc:
      echo "Failed to dial a peer: ", exc.msg

  # We will try to publish our address multiple times, in case
  # it takes time to establish connections with other GossipSub peers
  var published = false
  while not published:
    await sleepAsync(500.milliseconds)
    for fullAddr in switch.peerInfo.fullAddrs.tryGet():
      if (await gossip.publish("/tron/matchmaking", fullAddr.bytes)) == 0:
        published = false
        break
      published = true

  discoveryQuery.stop()

  # We now wait for someone to connect to us (or for us to connect to someone)
  let peerConn = await g.peerFound
  defer:
    await peerConn.closeWithEof()

  await g.mainLoop(peerConn)

let
  game = Game.new()
  netFut = networking(game)
nico.init("Status", "Tron")
nico.createWindow("Tron", mapSize * 4, mapSize * 4, 4, false)
nico.run(
  proc() =
    discard,
  proc(dt: float32) =
    game.update(dt),
  proc() =
    game.draw(),
)
waitFor(netFut.cancelAndWait())

## And that's it! If you want to run this code locally, the simplest way is to use the
## first node as a boot node for the second one. But you can also use any rendezvous node
