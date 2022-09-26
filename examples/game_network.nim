import os
import nico, chronos, ../libp2p, stew/byteutils, stew/endians2

type
  Player = ref object
    x, y: int
    currentDir, nextDir: int
    lost: bool
    color: int

  GameProto = ref object of LPProtocol

const directions = @[(K_UP, 0, -1), (K_LEFT, -1, 0), (K_DOWN, 0, 1), (K_RIGHT, 1, 0)]
var
  colorMap: array[32 * 32, int]
  start = 3.0
  ticks = 0
  localPlayer = Player(x: 4, y: 16, currentDir: 3, nextDir: 3, color: 8)
  remotePlayer = Player(x: 27, y: 16, currentDir: 1, nextDir: 1, color: 12)
  peer: Connection
  gameFinished = newFuture[void]()
  tickFinished: Future[int]

proc gameInit =
  for pos in 0 .. colorMap.high:
    if pos mod 32 in [0, 31] or pos div 32 in [0, 31]: colorMap[pos] = 7

proc tick(p: Player) =
  p.x += directions[p.currentDir][1]
  p.y += directions[p.currentDir][2]
  if colorMap[p.y * 32 + p.x] != 0: p.lost = true
  colorMap[p.y * 32 + p.x] = p.color

proc gameUpdate(dt: float32) =
  waitFor(sleepAsync(1.milliseconds))
  if isNil(peer) or isNil(tickFinished): return
  start -= dt

  for i in 0 .. directions.high:
    if i != (localPlayer.currentDir + 2 mod 4) and keyp(directions[i][0]):
      localPlayer.nextDir = i

  if start < -0.2 and not tickFinished.finished():
    localPlayer.currentDir = localPlayer.nextDir
    tickFinished.complete(localPlayer.currentDir)

proc gameMainLoop {.async.} =
  while not (localPlayer.lost or remotePlayer.lost):
    start = 0
    tickFinished = newFuture[int]()

    let dir = await tickFinished
    await peer.writeLp(toBytes(uint32(dir)))

    remotePlayer.currentDir = int uint32.fromBytes(await peer.readLp(8))
    remotePlayer.tick()
    localPlayer.tick()
  gameFinished.complete()

proc gameDraw =
  for pos, color in colorMap:
    setColor(color)
    boxFill(pos mod 32 * 4, pos div 32 * 4, 4, 4)
  let text = if isNil(peer): "Matchmaking.."
             elif start > 1.5: "Welcome to Etron"
             elif start > 0.0: "- " & $(int(start / 0.5) + 1) & " -"
             elif remotePlayer.lost and localPlayer.lost: "DEUCE"
             elif localPlayer.lost: "YOU LOOSE"
             elif remotePlayer.lost: "YOU WON"
             else: ""
  printc(text, screenWidth div 2, screenHeight div 2)

proc new(T: typedesc[GameProto]): T =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    defer: await conn.closeWithEof()
    if not isNil(peer):
      await conn.close()
      return
    await conn.writeLp("ok")
    if "ok" != string.fromBytes(await conn.readLp(1024)): return
    peer = conn
    asyncSpawn gameMainLoop()
    await gameFinished
  return T(codecs: @["/tron/1.0.0"], handler: handle)

proc networkInit {.async.} =
  let
    switch = newStandardSwitch()
    gameProto = GameProto.new()
    gossip = GossipSub.init(
      switch = switch,
      triggerSelf = false)

  switch.mount(gossip)
  switch.mount(gameProto)

  gossip.subscribe(
    "/tron/matchmaking",
    proc (topic: string, data: seq[byte]) {.async.} =
      if not isNil(peer): return

      let ma = MultiAddress.init(data)
      if ma.isErr: return

      try:
        let
          (peerId, multiAddress) = ma.get().parseFullAddress()
          stream = await switch.dial(peerId, @[multiAddress], gameProto.codec)

        await stream.writeLp("ok")
        if (await stream.readLp(10)) != "ok".toBytes: return
        peer = stream
        swap(localPlayer, remotePlayer)
        asyncSpawn gameMainLoop()
      except CatchableError as exc:
        discard
  )

  await switch.start()

  if paramCount() > 0:
    let (peerId, multiAddress) = paramStr(1).parseFullAddress()
    echo paramStr(1).parseFullAddress()
    await switch.connect(peerId, @[multiAddress])
  else:
    echo "Waiting for friends", switch.peerInfo.fullAddrs

  var published = false
  while not published:
    #TODO discover here
    await sleepAsync(1.seconds)
    for fullAddr in switch.peerInfo.fullAddrs:
      if (await gossip.publish("/tron/matchmaking", fullAddr.bytes)) == 0:
        published = false
        break
      published = true

  await gameFinished
  if not isNil(peer):
    await peer.closeWithEof()
  await switch.stop()

let networking = networkInit()
nico.init("Status", "Tron")
nico.createWindow("Tron", 128, 128, 4, false)
nico.run(gameInit, gameUpdate, gameDraw)
if not gameFinished.finished():
  gameFinished.complete()
waitFor(networking)
