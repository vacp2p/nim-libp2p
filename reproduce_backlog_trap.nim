import chronos
from chronos/transports/stream import StreamServer, accept, connect, StreamTransport

proc main() {.async.} =
  let server = createStreamServer(initTAddress("127.0.0.1:0"))
  let listenAddr = server.localAddress()
  echo "[Server] Listening on ", listenAddr

  # This async event simulates a Semaphore blocking like getIncomingSlot()
  var incomingSlotAvailable = newAsyncEvent()

  proc serverLoop() {.async.} =
    echo "[Server] Starting accept loop..."
    var acceptedCount = 0
    while true:
      if acceptedCount >= 1:
        echo "[Server] Max connections reached! getIncomingSlot() is blocking..."
        # Simulate switch.nim blocking on s.connManager.getIncomingSlot()
        await incomingSlotAvailable.wait()
        incomingSlotAvailable.clear()
        echo "[Server] Slot freed! Resuming accept()..."

      let conn = await server.accept()
      echo "[Server] Successfully accepted a connection from the OS!"
      inc acceptedCount

  asyncSpawn serverLoop()

  # Let server start
  await sleepAsync(100.milliseconds)

  echo "\n[Client 1] Attempting to connect..."
  let c1 = await connect(listenAddr)
  echo "[Client 1] Connection successful!"

  # Wait for server to process Client 1 and block
  await sleepAsync(500.milliseconds)

  echo "\n[Client 2] Attempting to connect while Server is blocked..."
  echo "[Client 2] Notice how connect() will succeed instantly because the OS Kernel completes the TCP handshake!"
  let c2 = await connect(listenAddr)
  echo "[Client 2] Connection successful! I think I'm connected to the application!"
  
  echo "\n[Client 2] Waiting for server to say something (like a noise handshake)..."
  try:
    # Client waits with a timeout of 3 seconds
    let data = await c2.read(10).wait(3.seconds)
    echo "[Client 2] Received data!"
  except AsyncTimeoutError:
    echo "[Client 2] ERROR: Timed out waiting for response! The server application never called accept() so it doesn't know I exist!"

  echo "\n[Server] Unblocking the server now..."
  incomingSlotAvailable.fire()
  
  await sleepAsync(500.milliseconds)
  echo "\n[Test Finished]"

  server.stop()
  server.close()

waitFor main()
