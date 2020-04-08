when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}
  
import chronos          # an efficient library for async

proc processInput(rfd: AsyncFD) {.async.} =
  echo "Type something below to see if the multithread IO works:\nType 'exit' to exit."

  let transp = fromPipe(rfd)
  while true:
    let a = await transp.readLine()

    if a == "exit":
      quit(0);

    echo "You just entered: " & a

proc readInput(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

proc main() {.async.} =
  let (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")
  
  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)
  
  await processInput(rfd)

when isMainModule:      # isMainModule = true when the module is compiled as the main file
  waitFor(main())
 