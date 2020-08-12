# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import chronos
import chronicles
import macros

# could not figure how to make it with a simple template
# sadly nim needs more love for hygenic templates
# so here goes the macro, its based on the proc/template version
# and uses quote do so it's quite readable

macro checkFutures*[T](futs: seq[Future[T]], exclude: untyped = []): untyped =
  let nexclude = exclude.len
  case nexclude
  of 0:
    quote do:
      for res in `futs`:
        if res.failed:
          let exc = res.readError()
          # We still don't abort but warn
          warn "A future has failed, enable trace logging for details", error = exc.name
          trace "Exception message", msg= exc.msg, stack = getStackTrace()
  else:
    quote do:
      for res in `futs`:
        block check:
          if res.failed:
            let exc = res.readError()
            for i in 0..<`nexclude`:
              if exc of `exclude`[i]:
                trace "A future has failed", error=exc.name, msg=exc.msg
                break check
            # We still don't abort but warn
            warn "A future has failed, enable trace logging for details", error=exc.name
            trace "Exception details", msg=exc.msg

proc allFuturesThrowing*[T](args: varargs[Future[T]]): Future[void] =
  var futs: seq[Future[T]]
  for fut in args:
    futs &= fut
  proc call() {.async.} =
    var first: ref Exception = nil
    futs = await allFinished(futs)
    for fut in futs:
      if fut.failed:
        let err = fut.readError()
        if err of Defect:
          raise err
        else:
          if err of CancelledError:
            raise err
          if isNil(first):
            first = err
    if not isNil(first):
      raise first

  return call()

template tryAndWarn*(message: static[string]; body: untyped): untyped =
  try:
    body
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "An exception has ocurred, enable trace logging for details", name = exc.name, msg = message
    trace "Exception details", exc = exc.msg

when defined(profiler_optick):
  import dynlib

  type
    OptickEvent* = distinct uint64
    OptickEventCtx* = distinct uint64

    OptickCreateEvent* = proc(inFunctionName: cstring, inFunctionLength: uint16, inFileName: cstring, inFileNameLenght: uint16, inFileLine: uint32): OptickEvent {.cdecl.}
    OptickPushEvent* = proc(event: OptickEvent): OptickEventCtx {.cdecl.}
    OptickPopEvent* = proc(ctx: OptickEventCtx) {.cdecl.}
    OptickStartCapture* = proc() {.cdecl.}
    OptickStopCapture* = proc(filename: cstring, nameLen: uint16) {.cdecl.}
    OptickNextFrame* = proc() {.cdecl.}

  var
    createEvent*: OptickCreateEvent
    pushEvent*: OptickPushEvent
    popEvent*: OptickPopEvent
    startCapture*: OptickStartCapture
    stopCapture*: OptickStopCapture
    nextFrame*: OptickNextFrame

  template profile*(name: string): untyped =
    var ev {.inject.}: OptickEventCtx
    defer:
        {.gcsafe.}:
          popEvent(ev)
    {.gcsafe.}:
      const pos = instantiationInfo()
      let event_desc {.global.} = createEvent(name.cstring, name.len.uint16, pos.filename.cstring, pos.filename.len.uint16, pos.line.uint32)
      ev = pushEvent(event_desc)

  proc getName(node: NimNode): string {.compileTime.} =
    case node.kind
    of nnkSym:
      return $node
    of nnkPostfix:
      return node[1].strVal
    of nnkIdent:
      return node.strVal
    of nnkEmpty:
      return "anonymous"
    else:
      error("Unknown name.")

  macro profiled*(p: untyped): untyped =
    let name = p.name.getName()
    var code = newStmtList()
    var keySym = genSym(nskLet)
    let body = p.body
    let newBody = quote do:
      {.gcsafe.}:
        const pos = instantiationInfo()
        let event_desc {.global.} = createEvent(`name`.cstring, `name`.len.uint16, pos.filename.cstring, pos.filename.len.uint16, pos.line.uint32)
        let `keySym` = pushEvent(event_desc)
        defer:
          popEvent(`keySym`)
        `body`
    p.body = newBody
    p

  proc load() =
    var candidates: seq[string]
    libCandidates("OptickCore", candidates)
    for c in candidates:
      let lib = loadLib("OptickCore")
      if lib != nil:
        createEvent = cast[OptickCreateEvent](lib.symAddr("OptickAPI_CreateEventDescription"))
        pushEvent = cast[OptickPushEvent](lib.symAddr("OptickAPI_PushEvent"))
        popEvent = cast[OptickPopEvent](lib.symAddr("OptickAPI_PopEvent"))
        startCapture = cast[OptickStartCapture](lib.symAddr("OptickAPI_StartCapture"))
        stopCapture = cast[OptickStopCapture](lib.symAddr("OptickAPI_StopCapture"))
        nextFrame = cast[OptickNextFrame](lib.symAddr("OptickAPI_NextFrame"))
        return
    doAssert(false, "OptickCore failed to load")
  
  load()

  startCapture()
  addQuitProc(proc () {.noconv.} = 
    stopCapture("profiled.opt", "profiled.opt".len))

  # proc frameTicker() {.async.} =
  #   while true:
  #     {.gcsafe.}:
  #       nextFrame()
  #     await sleepAsync(100.millis)
  
  # let poll_event = createEvent("poll", "poll".len, "", 0, 0)
  # proc pollHook() {.async.} =
  #   while true:
  #     {.gcsafe.}:
  #       let ev = pushEvent(poll_event)
  #       await sleepAsync(0)
  #       defer:
  #         popEvent(ev)
      
  
  # asyncCheck frameTicker()
  # asyncCheck pollHook()
else:
   macro profiled*(p: untyped): untyped =
    p