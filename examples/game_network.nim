import os
import nico, chronos, ../libp2p, stew/byteutils, stew/endians2

const
  directions = @[(K_UP, 0, -1), (K_LEFT, -1, 0), (K_DOWN, 0, 1), (K_RIGHT, 1, 0)]
  mapSize = 32

type
  Player = ref object
    x, y: int
    currentDir, nextDir: int
    lost: bool
    color: int

  Game = ref object
    colorMap: array[mapSize * mapSize, int]
    tickTime: float
    localPlayer, remotePlayer: Player
    peerFound: Future[Connection]
    tickFinished: Future[int]

  GameProto = ref object of LPProtocol

proc new(_: type[Game]): Game =
  result = Game(
    tickTime: -3.0,
    localPlayer: Player(x: 4, y: 16, currentDir: 3, nextDir: 3, color: 8),
    remotePlayer: Player(x: 27, y: 16, currentDir: 1, nextDir: 1, color: 12),
    peerFound: newFuture[Connection]()
  )
  for pos in 0 .. result.colorMap.high:
    if pos mod mapSize in [0, mapSize - 1] or pos div mapSize in [0, mapSize - 1]:
      result.colorMap[pos] = 7

proc tick(g: Game, p: Player) =
  p.x += directions[p.currentDir][1]
  p.y += directions[p.currentDir][2]
  if g.colorMap[p.y * mapSize + p.x] != 0: p.lost = true
  g.colorMap[p.y * mapSize + p.x] = p.color

proc update(g: Game, dt: float32) =
  waitFor(sleepAsync(1.milliseconds))
  if not(g.peerFound.finished()) or isNil(g.tickFinished): return
  g.tickTime += dt

  for i in 0 .. directions.high:
    if i != (g.localPlayer.currentDir + 2 mod 4) and keyp(directions[i][0]):
      g.localPlayer.nextDir = i

  if g.tickTime > 0.2 and not g.tickFinished.finished():
    g.localPlayer.currentDir = g.localPlayer.nextDir
    g.tickFinished.complete(g.localPlayer.currentDir)

proc draw(g: Game) =
  for pos, color in g.colorMap:
    setColor(color)
    boxFill(pos mod 32 * 4, pos div 32 * 4, 4, 4)
  let text = if not(g.peerFound.finished()): "Matchmaking.."
             elif g.tickTime < -1.5: "Welcome to Etron"
             elif g.tickTime < 0.0: "- " & $(int(abs(g.tickTime) / 0.5) + 1) & " -"
             elif g.remotePlayer.lost and g.localPlayer.lost: "DEUCE"
             elif g.localPlayer.lost: "YOU LOOSE"
             elif g.remotePlayer.lost: "YOU WON"
             else: ""
  printc(text, screenWidth div 2, screenHeight div 2)

proc mainLoop(g: Game, peer: Connection) {.async.} =
  while not (g.localPlayer.lost or g.remotePlayer.lost):
    g.tickTime = 0
    g.tickFinished = newFuture[int]()

    let dir = await g.tickFinished
    await peer.writeLp(toBytes(uint32(dir)))

    g.remotePlayer.currentDir = int uint32.fromBytes(await peer.readLp(8))
    g.tick(g.remotePlayer)
    g.tick(g.localPlayer)

proc new(T: typedesc[GameProto], g: Game): T =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    defer: await conn.closeWithEof()
    if g.peerFound.finished:
      await conn.close()
      return
    await conn.writeLp("ok")
    if "ok" != string.fromBytes(await conn.readLp(1024)): return
    g.peerFound.complete(conn)
    await conn.join()
  return T(codecs: @["/tron/1.0.0"], handler: handle)

proc networking(g: Game) {.async.} =
  let
    switch = newStandardSwitch()
    gameProto = GameProto.new(g)
    gossip = GossipSub.init(
      switch = switch,
      triggerSelf = false)

  switch.mount(gossip)
  switch.mount(gameProto)

  gossip.subscribe(
    "/tron/matchmaking",
    proc (topic: string, data: seq[byte]) {.async.} =
      if g.peerFound.finished: return

      try:
        let
          (peerId, multiAddress) = parseFullAddress(data).tryGet()
          stream = await switch.dial(peerId, @[multiAddress], gameProto.codec)

        await stream.writeLp("ok")
        if (await stream.readLp(10)) != "ok".toBytes: return
        g.peerFound.complete(stream)
        swap(g.localPlayer, g.remotePlayer)
      except CatchableError as exc:
        discard
  )

  await switch.start()

  if paramCount() > 0:
    let (peerId, multiAddress) = paramStr(1).parseFullAddress().tryGet()
    echo paramStr(1).parseFullAddress()
    await switch.connect(peerId, @[multiAddress])
  else:
    echo "Waiting for friends", switch.peerInfo.fullAddrs.tryGet()

  var published = false
  while not published:
    #TODO discover here
    await sleepAsync(1.seconds)
    for fullAddr in switch.peerInfo.fullAddrs.tryGet():
      if (await gossip.publish("/tron/matchmaking", fullAddr.bytes)) == 0:
        published = false
        break
      published = true

  let peerConn = await g.peerFound
  await g.mainLoop(peerConn)
  await peerConn.closeWithEof()
  await switch.stop()

let
  game = Game.new()
  netFut = networking(game)
nico.init("Status", "Tron")
nico.createWindow("Tron", mapSize * 4, mapSize * 4, 4, false)
nico.run(proc = discard, proc(dt: float32) = game.update(dt), proc = game.draw())
waitFor(netFut)
