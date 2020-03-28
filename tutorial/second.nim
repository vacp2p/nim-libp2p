when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

import chronos          # an efficient library for async, developed by Status

proc processInput(rfd: AsyncFD) {.async.} =
  var transp = fromPipe(rfd)
  while true:
    let a = await transp.readLine()
    echo "You just entered: " & a

proc readInput(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  var transp = fromPipe(wfd)

  while true:
    var line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

proc main() {.async.} =
  var (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")
  
  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)
  
  await processInput(rfd)

when isMainModule:      # isMainModule = true when the module is compiled as the main file
  waitFor(main())
 