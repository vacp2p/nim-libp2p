proc acquire*(lock: AsyncLock): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("acquire")
  iterator acquire_16475256(): FutureBase {.closure.} =
    ## Acquire a lock ``lock``.
    ## 
    ## This procedure blocks until the lock ``lock`` is unlocked, then sets it
    ## to locked and returns.
    if not (lock.locked) and lock.checkAll():
      lock.locked = true
    else:
      var w = newFuture[void]("AsyncLock.acquire")
      lock.waiters.add(w)
      try:
        try:
          await w
        finally:
          lock.removeWaiter(w)
      except CancelledError:
        if not (lock.locked):
          lock.wakeUpFirst()
        raise
      lock.locked = true
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym16475267 = acquire_16475256
  {.push, stackTrace: off.}
  proc acquire_continue_16475266(udata`gensym16475268: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym16475267.finished()):
        var next`gensym16475269 = nameIterVar`gensym16475267()
        while (not next`gensym16475269.isNil()) and
            next`gensym16475269.finished():
          next`gensym16475269 = nameIterVar`gensym16475267()
          if nameIterVar`gensym16475267.finished():
            break
        if next`gensym16475269 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym16475270 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym16475270 % "acquire")
        else:
          {.gcsafe.}:
            next`gensym16475269.addCallback(acquire_continue_16475266)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym16475271:
      if chronosInternalRetFuture.finished():
        raise exc`gensym16475271
      else:
        chronosInternalRetFuture.fail(exc`gensym16475271)

  acquire_continue_16475266()
  {.pop.}
  return chronosInternalRetFuture

proc wait*(event: AsyncEvent): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("wait")
  iterator wait_16550319(): FutureBase {.closure.} =
    ## Block until the internal flag of ``event`` is `true`.
    ## If the internal flag is `true` on entry, return immediately. Otherwise,
    ## block until another task calls `fire()` to set the flag to `true`,
    ## then return.
    if not (event.flag):
      var w = newFuture[void]("AsyncEvent.wait")
      event.waiters.add(w)
      try:
        await w
      finally:
        event.removeWaiter(w)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym16550321 = wait_16550319
  {.push, stackTrace: off.}
  proc wait_continue_16550320(udata`gensym16550322: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym16550321.finished()):
        var next`gensym16550323 = nameIterVar`gensym16550321()
        while (not next`gensym16550323.isNil()) and
            next`gensym16550323.finished():
          next`gensym16550323 = nameIterVar`gensym16550321()
          if nameIterVar`gensym16550321.finished():
            break
        if next`gensym16550323 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym16550324 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym16550324 % "wait")
        else:
          {.gcsafe.}:
            next`gensym16550323.addCallback(wait_continue_16550320)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym16550325:
      if chronosInternalRetFuture.finished():
        raise exc`gensym16550325
      else:
        chronosInternalRetFuture.fail(exc`gensym16550325)

  wait_continue_16550320()
  {.pop.}
  return chronosInternalRetFuture

proc addFirst*[T](aq: AsyncQueue[T]; item: T): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("addFirst")
  iterator addFirst_16706182(): FutureBase {.closure.} =
    ## Put an ``item`` to the beginning of the queue ``aq``. If the queue is full,
    ## wait until a free slot is available before adding item.
    while aq.full():
      var putter = newFuture[void]("AsyncQueue.addFirst")
      aq.putters.add(putter)
      try:
        await putter
      except:
        aq.putters.removeWaiter(putter)
        if not aq.full() and not (putter.cancelled()):
          aq.putters.wakeupNext()
        raise
    aq.addFirstNoWait(item)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym16706184 = addFirst_16706182
  {.push, stackTrace: off.}
  proc addFirst_continue_16706183(udata`gensym16706185: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym16706184.finished()):
        var next`gensym16706186 = nameIterVar`gensym16706184()
        while (not next`gensym16706186.isNil()) and
            next`gensym16706186.finished():
          next`gensym16706186 = nameIterVar`gensym16706184()
          if nameIterVar`gensym16706184.finished():
            break
        if next`gensym16706186 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym16706187 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym16706187 % "addFirst")
        else:
          {.gcsafe.}:
            next`gensym16706186.addCallback(addFirst_continue_16706183)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym16706188:
      if chronosInternalRetFuture.finished():
        raise exc`gensym16706188
      else:
        chronosInternalRetFuture.fail(exc`gensym16706188)

  addFirst_continue_16706183()
  {.pop.}
  return chronosInternalRetFuture

proc addLast*[T](aq: AsyncQueue[T]; item: T): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("addLast")
  iterator addLast_16710047(): FutureBase {.closure.} =
    ## Put an ``item`` to the end of the queue ``aq``. If the queue is full,
    ## wait until a free slot is available before adding item.
    while aq.full():
      var putter = newFuture[void]("AsyncQueue.addLast")
      aq.putters.add(putter)
      try:
        await putter
      except:
        aq.putters.removeWaiter(putter)
        if not aq.full() and not (putter.cancelled()):
          aq.putters.wakeupNext()
        raise
    aq.addLastNoWait(item)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym16710049 = addLast_16710047
  {.push, stackTrace: off.}
  proc addLast_continue_16710048(udata`gensym16710050: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym16710049.finished()):
        var next`gensym16710051 = nameIterVar`gensym16710049()
        while (not next`gensym16710051.isNil()) and
            next`gensym16710051.finished():
          next`gensym16710051 = nameIterVar`gensym16710049()
          if nameIterVar`gensym16710049.finished():
            break
        if next`gensym16710051 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym16710052 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym16710052 % "addLast")
        else:
          {.gcsafe.}:
            next`gensym16710051.addCallback(addLast_continue_16710048)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym16710053:
      if chronosInternalRetFuture.finished():
        raise exc`gensym16710053
      else:
        chronosInternalRetFuture.fail(exc`gensym16710053)

  addLast_continue_16710048()
  {.pop.}
  return chronosInternalRetFuture

proc popFirst*[T](aq: AsyncQueue[T]): Future[T] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[T]("popFirst")
  iterator popFirst_16715051(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: T
    {.pop.}
    ## Remove and return an ``item`` from the beginning of the queue ``aq``.
    ## If the queue is empty, wait until an item is available.
    while aq.empty():
      var getter = newFuture[void]("AsyncQueue.popFirst")
      aq.getters.add(getter)
      try:
        await getter
      except:
        aq.getters.removeWaiter(getter)
        if not (aq.empty()) and not (getter.cancelled()):
          aq.getters.wakeupNext()
        raise
    result = aq.popFirstNoWait()
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym16715068 = popFirst_16715051
  {.push, stackTrace: off.}
  proc popFirst_continue_16715067(udata`gensym16715069: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym16715068.finished()):
        var next`gensym16715070 = nameIterVar`gensym16715068()
        while (not next`gensym16715070.isNil()) and
            next`gensym16715070.finished():
          next`gensym16715070 = nameIterVar`gensym16715068()
          if nameIterVar`gensym16715068.finished():
            break
        if next`gensym16715070 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym16715071 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym16715071 % "popFirst")
        else:
          {.gcsafe.}:
            next`gensym16715070.addCallback(popFirst_continue_16715067)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym16715072:
      if chronosInternalRetFuture.finished():
        raise exc`gensym16715072
      else:
        chronosInternalRetFuture.fail(exc`gensym16715072)

  popFirst_continue_16715067()
  {.pop.}
  return chronosInternalRetFuture

proc popLast*[T](aq: AsyncQueue[T]): Future[T] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[T]("popLast")
  iterator popLast_16720044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: T
    {.pop.}
    ## Remove and return an ``item`` from the end of the queue ``aq``.
    ## If the queue is empty, wait until an item is available.
    while aq.empty():
      var getter = newFuture[void]("AsyncQueue.popLast")
      aq.getters.add(getter)
      try:
        await getter
      except:
        aq.getters.removeWaiter(getter)
        if not (aq.empty()) and not (getter.cancelled()):
          aq.getters.wakeupNext()
        raise
    result = aq.popLastNoWait()
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym16720046 = popLast_16720044
  {.push, stackTrace: off.}
  proc popLast_continue_16720045(udata`gensym16720047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym16720046.finished()):
        var next`gensym16720048 = nameIterVar`gensym16720046()
        while (not next`gensym16720048.isNil()) and
            next`gensym16720048.finished():
          next`gensym16720048 = nameIterVar`gensym16720046()
          if nameIterVar`gensym16720046.finished():
            break
        if next`gensym16720048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym16720049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym16720049 % "popLast")
        else:
          {.gcsafe.}:
            next`gensym16720048.addCallback(popLast_continue_16720045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym16720050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym16720050
      else:
        chronosInternalRetFuture.fail(exc`gensym16720050)

  popLast_continue_16720045()
  {.pop.}
  return chronosInternalRetFuture

proc readExactly*(transp: StreamTransport; pbytes: pointer; nbytes: int): Future[void] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("readExactly")
  iterator readExactly_18545046(): FutureBase {.closure.} =
    ## Read exactly ``nbytes`` bytes from transport ``transp`` and store it to
    ## ``pbytes``.
    ## 
    ## If EOF is received and ``nbytes`` is not yet readed, the procedure
    ## will raise ``TransportIncompleteError``, potentially with some bytes
    ## already written.
    var index = 0
    var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)
    readLoop("stream.transport.readExactly"):
      if transp.offset == 0:
        if transp.atEof():
          raise newException(TransportIncompleteError, "Data incomplete!")
      let count = min(nbytes - index, transp.offset)
      if count > 0:
        copyMem(addr pbuffer[index], addr(transp.buffer[0]), count)
        index += count
      (consumed: count, done: index == nbytes)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym18545048 = readExactly_18545046
  {.push, stackTrace: off.}
  proc readExactly_continue_18545047(udata`gensym18545049: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym18545048.finished()):
        var next`gensym18545050 = nameIterVar`gensym18545048()
        while (not next`gensym18545050.isNil()) and
            next`gensym18545050.finished():
          next`gensym18545050 = nameIterVar`gensym18545048()
          if nameIterVar`gensym18545048.finished():
            break
        if next`gensym18545050 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym18545051 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym18545051 % "readExactly")
        else:
          {.gcsafe.}:
            next`gensym18545050.addCallback(readExactly_continue_18545047)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym18545052:
      if chronosInternalRetFuture.finished():
        raise exc`gensym18545052
      else:
        chronosInternalRetFuture.fail(exc`gensym18545052)

  readExactly_continue_18545047()
  {.pop.}
  return chronosInternalRetFuture

proc readOnce*(transp: StreamTransport; pbytes: pointer; nbytes: int): Future[int] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[int]("readOnce")
  iterator readOnce_18705044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: int
    {.pop.}
    ## Perform one read operation on transport ``transp``.
    ## 
    ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
    ## internal buffer, otherwise it will wait until some bytes will be received.
    var count = 0
    readLoop("stream.transport.readOnce"):
      if transp.offset == 0:
        (0, transp.atEof())
      else:
        count = min(transp.offset, nbytes)
        copyMem(pbytes, addr(transp.buffer[0]), count)
        (count, true)
    complete(chronosInternalRetFuture, count)
    return nil
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym18705046 = readOnce_18705044
  {.push, stackTrace: off.}
  proc readOnce_continue_18705045(udata`gensym18705047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym18705046.finished()):
        var next`gensym18705048 = nameIterVar`gensym18705046()
        while (not next`gensym18705048.isNil()) and
            next`gensym18705048.finished():
          next`gensym18705048 = nameIterVar`gensym18705046()
          if nameIterVar`gensym18705046.finished():
            break
        if next`gensym18705048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym18705049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym18705049 % "readOnce")
        else:
          {.gcsafe.}:
            next`gensym18705048.addCallback(readOnce_continue_18705045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym18705050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym18705050
      else:
        chronosInternalRetFuture.fail(exc`gensym18705050)

  readOnce_continue_18705045()
  {.pop.}
  return chronosInternalRetFuture

proc readUntil*(transp: StreamTransport; pbytes: pointer; nbytes: int; sep: seq[byte]): Future[
    int] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[int]("readUntil")
  iterator readUntil_18870044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: int
    {.pop.}
    ## Read data from the transport ``transp`` until separator ``sep`` is found.
    ## 
    ## On success, the data and separator will be removed from the internal
    ## buffer (consumed). Returned data will include the separator at the end.
    ## 
    ## If EOF is received, and `sep` was not found, procedure will raise
    ## ``TransportIncompleteError``.
    ## 
    ## If ``nbytes`` bytes has been received and `sep` was not found, procedure
    ## will raise ``TransportLimitError``.
    ## 
    ## Procedure returns actual number of bytes read.
    var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)
    var state = 0
    var k = 0
    readLoop("stream.transport.readUntil"):
      if transp.atEof():
        raise newException(TransportIncompleteError, "Data incomplete!")
      var index = 0
      while index < transp.offset:
        if k >= nbytes:
          raise newException(TransportLimitError, "Limit reached!")
        let ch = transp.buffer[index]
        inc(index)
        pbuffer[k] = ch
        inc(k)
        if sep[state] == ch:
          inc(state)
          if state == len(sep):
            break
        else:
          state = 0
      (index, state == len(sep))
    complete(chronosInternalRetFuture, k)
    return nil
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym18870046 = readUntil_18870044
  {.push, stackTrace: off.}
  proc readUntil_continue_18870045(udata`gensym18870047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym18870046.finished()):
        var next`gensym18870048 = nameIterVar`gensym18870046()
        while (not next`gensym18870048.isNil()) and
            next`gensym18870048.finished():
          next`gensym18870048 = nameIterVar`gensym18870046()
          if nameIterVar`gensym18870046.finished():
            break
        if next`gensym18870048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym18870049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym18870049 % "readUntil")
        else:
          {.gcsafe.}:
            next`gensym18870048.addCallback(readUntil_continue_18870045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym18870050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym18870050
      else:
        chronosInternalRetFuture.fail(exc`gensym18870050)

  readUntil_continue_18870045()
  {.pop.}
  return chronosInternalRetFuture

proc readLine*(transp: StreamTransport; limit = 0; sep = "\c\n"): Future[string] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[string]("readLine")
  iterator readLine_19045044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: string
    {.pop.}
    ## Read one line from transport ``transp``, where "line" is a sequence of
    ## bytes ending with ``sep`` (default is "\r\n").
    ## 
    ## If EOF is received, and ``sep`` was not found, the method will return the
    ## partial read bytes.
    ## 
    ## If the EOF was received and the internal buffer is empty, return an
    ## empty string.
    ## 
    ## If ``limit`` more then 0, then read is limited to ``limit`` bytes.
    let lim = if limit <= 0:
      -1 else:
      limit
    var state = 0
    readLoop("stream.transport.readLine"):
      if transp.atEof():
        (0, true)
      else:
        var index = 0
        while index < transp.offset:
          let ch = char(transp.buffer[index])
          index += 1
          if sep[state] == ch:
            inc(state)
            if state == len(sep):
              break
          else:
            if state != 0:
              if limit > 0:
                let missing = min(state, lim - len(result) - 1)
                result.add(sep[0 ..< missing])
              else:
                result.add(sep[0 ..< state])
              state = 0
            result.add(ch)
            if len(result) == lim:
              break
        (index, (state == len(sep)) or (lim == len(result)))
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym19045046 = readLine_19045044
  {.push, stackTrace: off.}
  proc readLine_continue_19045045(udata`gensym19045047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym19045046.finished()):
        var next`gensym19045048 = nameIterVar`gensym19045046()
        while (not next`gensym19045048.isNil()) and
            next`gensym19045048.finished():
          next`gensym19045048 = nameIterVar`gensym19045046()
          if nameIterVar`gensym19045046.finished():
            break
        if next`gensym19045048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym19045049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym19045049 % "readLine")
        else:
          {.gcsafe.}:
            next`gensym19045048.addCallback(readLine_continue_19045045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym19045050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym19045050
      else:
        chronosInternalRetFuture.fail(exc`gensym19045050)

  readLine_continue_19045045()
  {.pop.}
  return chronosInternalRetFuture

proc read*(transp: StreamTransport): Future[seq[byte]] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[seq[byte]]("read")
  iterator read_19240073(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: seq[byte]
    {.pop.}
    ## Read all bytes from transport ``transp``.
    ## 
    ## This procedure allocates buffer seq[byte] and return it as result.
    readLoop("stream.transport.read"):
      if transp.atEof():
        (0, true)
      else:
        result.add(transp.buffer.toOpenArray(0, transp.offset - 1))
        (transp.offset, false)
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym19240075 = read_19240073
  {.push, stackTrace: off.}
  proc read_continue_19240074(udata`gensym19240076: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym19240075.finished()):
        var next`gensym19240077 = nameIterVar`gensym19240075()
        while (not next`gensym19240077.isNil()) and
            next`gensym19240077.finished():
          next`gensym19240077 = nameIterVar`gensym19240075()
          if nameIterVar`gensym19240075.finished():
            break
        if next`gensym19240077 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym19240078 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym19240078 % "read")
        else:
          {.gcsafe.}:
            next`gensym19240077.addCallback(read_continue_19240074)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym19240079:
      if chronosInternalRetFuture.finished():
        raise exc`gensym19240079
      else:
        chronosInternalRetFuture.fail(exc`gensym19240079)

  read_continue_19240074()
  {.pop.}
  return chronosInternalRetFuture

proc read*(transp: StreamTransport; n: int): Future[seq[byte]] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[seq[byte]]("read")
  iterator read_19415073(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: seq[byte]
    {.pop.}
    ## Read all bytes (n <= 0) or exactly `n` bytes from transport ``transp``.
    ## 
    ## This procedure allocates buffer seq[byte] and return it as result.
    if n <= 0:
      complete(chronosInternalRetFuture, await transp.read())
      return nil
    else:
      readLoop("stream.transport.read"):
        if transp.atEof():
          (0, true)
        else:
          let count = min(transp.offset, n - len(result))
          result.add(transp.buffer.toOpenArray(0, count - 1))
          (count, len(result) == n)
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym19415075 = read_19415073
  {.push, stackTrace: off.}
  proc read_continue_19415074(udata`gensym19415076: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym19415075.finished()):
        var next`gensym19415077 = nameIterVar`gensym19415075()
        while (not next`gensym19415077.isNil()) and
            next`gensym19415077.finished():
          next`gensym19415077 = nameIterVar`gensym19415075()
          if nameIterVar`gensym19415075.finished():
            break
        if next`gensym19415077 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym19415078 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym19415078 % "read")
        else:
          {.gcsafe.}:
            next`gensym19415077.addCallback(read_continue_19415074)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym19415079:
      if chronosInternalRetFuture.finished():
        raise exc`gensym19415079
      else:
        chronosInternalRetFuture.fail(exc`gensym19415079)

  read_continue_19415074()
  {.pop.}
  return chronosInternalRetFuture

proc consume*(transp: StreamTransport): Future[int] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[int]("consume")
  iterator consume_19580044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: int
    {.pop.}
    ## Consume all bytes from transport ``transp`` and discard it.
    ## 
    ## Return number of bytes actually consumed and discarded.
    readLoop("stream.transport.consume"):
      if transp.atEof():
        (0, true)
      else:
        result += transp.offset
        (transp.offset, false)
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym19580046 = consume_19580044
  {.push, stackTrace: off.}
  proc consume_continue_19580045(udata`gensym19580047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym19580046.finished()):
        var next`gensym19580048 = nameIterVar`gensym19580046()
        while (not next`gensym19580048.isNil()) and
            next`gensym19580048.finished():
          next`gensym19580048 = nameIterVar`gensym19580046()
          if nameIterVar`gensym19580046.finished():
            break
        if next`gensym19580048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym19580049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym19580049 % "consume")
        else:
          {.gcsafe.}:
            next`gensym19580048.addCallback(consume_continue_19580045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym19580050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym19580050
      else:
        chronosInternalRetFuture.fail(exc`gensym19580050)

  consume_continue_19580045()
  {.pop.}
  return chronosInternalRetFuture

proc consume*(transp: StreamTransport; n: int): Future[int] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[int]("consume")
  iterator consume_19730044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: int
    {.pop.}
    ## Consume all bytes (n <= 0) or ``n`` bytes from transport ``transp`` and
    ## discard it.
    ## 
    ## Return number of bytes actually consumed and discarded.
    if n <= 0:
      complete(chronosInternalRetFuture, await transp.consume())
      return nil
    else:
      readLoop("stream.transport.consume"):
        if transp.atEof():
          (0, true)
        else:
          let count = min(transp.offset, n - result)
          result += count
          (count, result == n)
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym19730046 = consume_19730044
  {.push, stackTrace: off.}
  proc consume_continue_19730045(udata`gensym19730047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym19730046.finished()):
        var next`gensym19730048 = nameIterVar`gensym19730046()
        while (not next`gensym19730048.isNil()) and
            next`gensym19730048.finished():
          next`gensym19730048 = nameIterVar`gensym19730046()
          if nameIterVar`gensym19730046.finished():
            break
        if next`gensym19730048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym19730049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym19730049 % "consume")
        else:
          {.gcsafe.}:
            next`gensym19730048.addCallback(consume_continue_19730045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym19730050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym19730050
      else:
        chronosInternalRetFuture.fail(exc`gensym19730050)

  consume_continue_19730045()
  {.pop.}
  return chronosInternalRetFuture

proc readMessage*(transp: StreamTransport; predicate: ReadMessagePredicate): Future[
    void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("readMessage")
  iterator readMessage_19895044(): FutureBase {.closure.} =
    ## Read all bytes from transport ``transp`` until ``predicate`` callback
    ## will not be satisfied.
    ## 
    ## ``predicate`` callback should return tuple ``(consumed, result)``, where
    ## ``consumed`` is the number of bytes processed and ``result`` is a
    ## completion flag (``true`` if readMessage() should stop reading data,
    ## or ``false`` if readMessage() should continue to read data from transport).
    ## 
    ## ``predicate`` callback must copy all the data from ``data`` array and
    ## return number of bytes it is going to consume.
    ## ``predicate`` callback will receive (zero-length) openarray, if transport
    ## is at EOF.
    readLoop("stream.transport.readMessage"):
      if transp.offset == 0:
        if transp.atEof():
          predicate([])
        else:
          (0, false)
      else:
        predicate(transp.buffer.toOpenArray(0, transp.offset - 1))
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym19895046 = readMessage_19895044
  {.push, stackTrace: off.}
  proc readMessage_continue_19895045(udata`gensym19895047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym19895046.finished()):
        var next`gensym19895048 = nameIterVar`gensym19895046()
        while (not next`gensym19895048.isNil()) and
            next`gensym19895048.finished():
          next`gensym19895048 = nameIterVar`gensym19895046()
          if nameIterVar`gensym19895046.finished():
            break
        if next`gensym19895048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym19895049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym19895049 % "readMessage")
        else:
          {.gcsafe.}:
            next`gensym19895048.addCallback(readMessage_continue_19895045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym19895050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym19895050
      else:
        chronosInternalRetFuture.fail(exc`gensym19895050)

  readMessage_continue_19895045()
  {.pop.}
  return chronosInternalRetFuture

proc upload*(sb: ptr AsyncBuffer; pbytes: ptr byte; nbytes: int): Future[void] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("upload")
  iterator upload_20265036(): FutureBase {.closure.} =
    var length = nbytes
    while length > 0:
      let size = min(length, sb[].bufferLen())
      if size == 0:
        await sb[].transfer()
        continue
      else:
        copyMem(addr sb[].buffer[sb.offset], pbytes, size)
        sb[].offset = sb[].offset + size
        length = length - size
    sb[].forget()
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym20265038 = upload_20265036
  {.push, stackTrace: off.}
  proc upload_continue_20265037(udata`gensym20265039: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym20265038.finished()):
        var next`gensym20265040 = nameIterVar`gensym20265038()
        while (not next`gensym20265040.isNil()) and
            next`gensym20265040.finished():
          next`gensym20265040 = nameIterVar`gensym20265038()
          if nameIterVar`gensym20265038.finished():
            break
        if next`gensym20265040 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20265041 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20265041 % "upload")
        else:
          {.gcsafe.}:
            next`gensym20265040.addCallback(upload_continue_20265037)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20265042:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20265042
      else:
        chronosInternalRetFuture.fail(exc`gensym20265042)

  upload_continue_20265037()
  {.pop.}
  return chronosInternalRetFuture

proc readExactly*(rstream: AsyncStreamReader; pbytes: pointer; nbytes: int): Future[
    void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("readExactly")
  iterator readExactly_20370473(): FutureBase {.closure.} =
    ## Read exactly ``nbytes`` bytes from read-only stream ``rstream`` and store
    ## it to ``pbytes``.
    ## 
    ## If EOF is received and ``nbytes`` is not yet readed, the procedure
    ## will raise ``AsyncStreamIncompleteError``.
    if not rstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if isNil(rstream.rsource):
      try:
        await readExactly(rstream.tsource, pbytes, nbytes)
      except CancelledError:
        raise
      except TransportIncompleteError:
        raise newAsyncStreamIncompleteError()
      except CatchableError as exc:
        raise newAsyncStreamReadError(exc)
    else:
      if isNil(rstream.readerLoop):
        await readExactly(rstream.rsource, pbytes, nbytes)
      else:
        var index = 0
        while true:
          let datalen = rstream.buffer.dataLen()
          if rstream.state == Error:
            raise newAsyncStreamReadError(rstream.error)
          if datalen == 0 and rstream.atEof():
            raise newAsyncStreamIncompleteError()
          if datalen >= (nbytes - index):
            rstream.buffer.copyData(pbytes, index, nbytes - index)
            rstream.buffer.shift(nbytes - index)
            break
          else:
            rstream.buffer.copyData(pbytes, index, datalen)
            index += datalen
            rstream.buffer.shift(datalen)
          await rstream.buffer.wait()
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym20370475 = readExactly_20370473
  {.push, stackTrace: off.}
  proc readExactly_continue_20370474(udata`gensym20370476: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym20370475.finished()):
        var next`gensym20370477 = nameIterVar`gensym20370475()
        while (not next`gensym20370477.isNil()) and
            next`gensym20370477.finished():
          next`gensym20370477 = nameIterVar`gensym20370475()
          if nameIterVar`gensym20370475.finished():
            break
        if next`gensym20370477 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20370478 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20370478 % "readExactly")
        else:
          {.gcsafe.}:
            next`gensym20370477.addCallback(readExactly_continue_20370474)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20370479:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20370479
      else:
        chronosInternalRetFuture.fail(exc`gensym20370479)

  readExactly_continue_20370474()
  {.pop.}
  return chronosInternalRetFuture

proc readOnce*(rstream: AsyncStreamReader; pbytes: pointer; nbytes: int): Future[int] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[int]("readOnce")
  iterator readOnce_20440044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: int
    {.pop.}
    ## Perform one read operation on read-only stream ``rstream``.
    ## 
    ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
    ## internal buffer, otherwise it will wait until some bytes will be received.
    if not rstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if isNil(rstream.rsource):
      try:
        result = await readOnce(rstream.tsource, pbytes, nbytes)
      except CancelledError:
        raise
      except CatchableError as exc:
        raise newAsyncStreamReadError(exc)
    else:
      if isNil(rstream.readerLoop):
        result = await readOnce(rstream.rsource, pbytes, nbytes)
      else:
        while true:
          let datalen = rstream.buffer.dataLen()
          if rstream.state == Error:
            raise newAsyncStreamReadError(rstream.error)
          if datalen == 0:
            if rstream.atEof():
              result = 0
              break
            await rstream.buffer.wait()
          else:
            let size = min(datalen, nbytes)
            rstream.buffer.copyData(pbytes, 0, size)
            rstream.buffer.shift(size)
            result = size
            break
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym20440046 = readOnce_20440044
  {.push, stackTrace: off.}
  proc readOnce_continue_20440045(udata`gensym20440047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym20440046.finished()):
        var next`gensym20440048 = nameIterVar`gensym20440046()
        while (not next`gensym20440048.isNil()) and
            next`gensym20440048.finished():
          next`gensym20440048 = nameIterVar`gensym20440046()
          if nameIterVar`gensym20440046.finished():
            break
        if next`gensym20440048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20440049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20440049 % "readOnce")
        else:
          {.gcsafe.}:
            next`gensym20440048.addCallback(readOnce_continue_20440045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20440050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20440050
      else:
        chronosInternalRetFuture.fail(exc`gensym20440050)

  readOnce_continue_20440045()
  {.pop.}
  return chronosInternalRetFuture

proc readUntil*(rstream: AsyncStreamReader; pbytes: pointer; nbytes: int;
               sep: seq[byte]): Future[int] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[int]("readUntil")
  iterator readUntil_20505044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: int
    {.pop.}
    ## Read data from the read-only stream ``rstream`` until separator ``sep`` is
    ## found.
    ## 
    ## On success, the data and separator will be removed from the internal
    ## buffer (consumed). Returned data will include the separator at the end.
    ## 
    ## If EOF is received, and `sep` was not found, procedure will raise
    ## ``AsyncStreamIncompleteError``.
    ## 
    ## If ``nbytes`` bytes has been received and `sep` was not found, procedure
    ## will raise ``AsyncStreamLimitError``.
    ## 
    ## Procedure returns actual number of bytes read.
    if not rstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if isNil(rstream.rsource):
      try:
        result = await readUntil(rstream.tsource, pbytes, nbytes, sep)
      except CancelledError:
        raise
      except TransportIncompleteError:
        raise newAsyncStreamIncompleteError()
      except TransportLimitError:
        raise newAsyncStreamLimitError()
      except CatchableError as exc:
        raise newAsyncStreamReadError(exc)
    else:
      if isNil(rstream.readerLoop):
        result = await readUntil(rstream.rsource, pbytes, nbytes, sep)
      else:
        var
          dest = cast[ptr UncheckedArray[byte]](pbytes)
          state = 0
          k = 0
        while true:
          let datalen = rstream.buffer.dataLen()
          if rstream.state == Error:
            raise newAsyncStreamReadError(rstream.error)
          if datalen == 0 and rstream.atEof():
            raise newAsyncStreamIncompleteError()
          var index = 0
          while index < datalen:
            let ch = rstream.buffer[index]
            if sep[state] == ch:
              inc(state)
            else:
              state = 0
            if k < nbytes:
              dest[k] = ch
              inc(k)
            else:
              raise newAsyncStreamLimitError()
            if state == len(sep):
              break
            inc(index)
          if state == len(sep):
            rstream.buffer.shift(index + 1)
            result = k
            break
          else:
            rstream.buffer.shift(datalen)
            await rstream.buffer.wait()
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym20505046 = readUntil_20505044
  {.push, stackTrace: off.}
  proc readUntil_continue_20505045(udata`gensym20505047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym20505046.finished()):
        var next`gensym20505048 = nameIterVar`gensym20505046()
        while (not next`gensym20505048.isNil()) and
            next`gensym20505048.finished():
          next`gensym20505048 = nameIterVar`gensym20505046()
          if nameIterVar`gensym20505046.finished():
            break
        if next`gensym20505048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20505049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20505049 % "readUntil")
        else:
          {.gcsafe.}:
            next`gensym20505048.addCallback(readUntil_continue_20505045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20505050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20505050
      else:
        chronosInternalRetFuture.fail(exc`gensym20505050)

  readUntil_continue_20505045()
  {.pop.}
  return chronosInternalRetFuture

proc readLine*(rstream: AsyncStreamReader; limit = 0; sep = "\c\n"): Future[string] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[string]("readLine")
  iterator readLine_20570044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: string
    {.pop.}
    ## Read one line from read-only stream ``rstream``, where ``"line"`` is a
    ## sequence of bytes ending with ``sep`` (default is ``"\r\n"``).
    ## 
    ## If EOF is received, and ``sep`` was not found, the method will return the
    ## partial read bytes.
    ## 
    ## If the EOF was received and the internal buffer is empty, return an
    ## empty string.
    ## 
    ## If ``limit`` more then 0, then result string will be limited to ``limit``
    ## bytes.
    if not rstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if isNil(rstream.rsource):
      try:
        result = await readLine(rstream.tsource, limit, sep)
      except CancelledError:
        raise
      except CatchableError as exc:
        raise newAsyncStreamReadError(exc)
    else:
      if isNil(rstream.readerLoop):
        result = await readLine(rstream.rsource, limit, sep)
      else:
        var res = ""
        var
          lim = if limit <= 0:
            -1 else:
            limit
          state = 0
        while true:
          let datalen = rstream.buffer.dataLen()
          if rstream.state == Error:
            raise newAsyncStreamReadError(rstream.error)
          if datalen == 0 and rstream.atEof():
            result = res
            break
          var index = 0
          while index < datalen:
            let ch = char(rstream.buffer[index])
            if sep[state] == ch:
              inc(state)
              if state == len(sep) or len(res) == lim:
                rstream.buffer.shift(index + 1)
                break
            else:
              state = 0
              res.add(ch)
              if len(res) == lim:
                rstream.buffer.shift(index + 1)
                break
            inc(index)
          if state == len(sep) or (lim == len(res)):
            result = res
            break
          else:
            rstream.buffer.shift(datalen)
            await rstream.buffer.wait()
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym20570046 = readLine_20570044
  {.push, stackTrace: off.}
  proc readLine_continue_20570045(udata`gensym20570047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym20570046.finished()):
        var next`gensym20570048 = nameIterVar`gensym20570046()
        while (not next`gensym20570048.isNil()) and
            next`gensym20570048.finished():
          next`gensym20570048 = nameIterVar`gensym20570046()
          if nameIterVar`gensym20570046.finished():
            break
        if next`gensym20570048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20570049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20570049 % "readLine")
        else:
          {.gcsafe.}:
            next`gensym20570048.addCallback(readLine_continue_20570045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20570050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20570050
      else:
        chronosInternalRetFuture.fail(exc`gensym20570050)

  readLine_continue_20570045()
  {.pop.}
  return chronosInternalRetFuture

proc read*(rstream: AsyncStreamReader; n = 0): Future[seq[byte]] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[seq[byte]]("read")
  iterator read_20635044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: seq[byte]
    {.pop.}
    ## Read all bytes (n <= 0) or exactly `n` bytes from read-only stream
    ## ``rstream``.
    ## 
    ## This procedure allocates buffer seq[byte] and return it as result.
    if not rstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if isNil(rstream.rsource):
      try:
        result = await read(rstream.tsource, n)
      except CancelledError:
        raise
      except CatchableError as exc:
        raise newAsyncStreamReadError(exc)
    else:
      if isNil(rstream.readerLoop):
        result = await read(rstream.rsource, n)
      else:
        var res = newSeq[byte]()
        while true:
          let datalen = rstream.buffer.dataLen()
          if rstream.state == Error:
            raise newAsyncStreamReadError(rstream.error)
          if datalen == 0 and rstream.atEof():
            result = res
            break
          if datalen > 0:
            let s = len(res)
            let o = s + datalen
            if n <= 0:
              res.setLen(o)
              rstream.buffer.copyData(addr res[s], 0, datalen)
              rstream.buffer.shift(datalen)
            else:
              let left = n - s
              if datalen >= left:
                res.setLen(n)
                rstream.buffer.copyData(addr res[s], 0, left)
                rstream.buffer.shift(left)
                result = res
                break
              else:
                res.setLen(o)
                rstream.buffer.copyData(addr res[s], 0, datalen)
                rstream.buffer.shift(datalen)
          await rstream.buffer.wait()
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym20635046 = read_20635044
  {.push, stackTrace: off.}
  proc read_continue_20635045(udata`gensym20635047: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym20635046.finished()):
        var next`gensym20635048 = nameIterVar`gensym20635046()
        while (not next`gensym20635048.isNil()) and
            next`gensym20635048.finished():
          next`gensym20635048 = nameIterVar`gensym20635046()
          if nameIterVar`gensym20635046.finished():
            break
        if next`gensym20635048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20635049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20635049 % "read")
        else:
          {.gcsafe.}:
            next`gensym20635048.addCallback(read_continue_20635045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20635050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20635050
      else:
        chronosInternalRetFuture.fail(exc`gensym20635050)

  read_continue_20635045()
  {.pop.}
  return chronosInternalRetFuture

proc consume*(rstream: AsyncStreamReader; n = -1): Future[int] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[int]("consume")
  iterator consume_20710044(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: int
    {.pop.}
    ## Consume (discard) all bytes (n <= 0) or ``n`` bytes from read-only stream
    ## ``rstream``.
    ## 
    ## Return number of bytes actually consumed (discarded).
    if not rstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if isNil(rstream.rsource):
      try:
        result = await consume(rstream.tsource, n)
      except CancelledError:
        raise
      except TransportLimitError:
        raise newAsyncStreamLimitError()
      except CatchableError as exc:
        raise newAsyncStreamReadError(exc)
    else:
      if isNil(rstream.readerLoop):
        result = await consume(rstream.rsource, n)
      else:
        var res = 0
        while true:
          let datalen = rstream.buffer.dataLen()
          if rstream.state == Error:
            raise newAsyncStreamReadError(rstream.error)
          if datalen == 0:
            if rstream.atEof():
              if n <= 0:
                result = res
                break
              else:
                raise newAsyncStreamLimitError()
          else:
            if n <= 0:
              res += datalen
              rstream.buffer.shift(datalen)
            else:
              let left = n - res
              if datalen >= left:
                res += left
                rstream.buffer.shift(left)
                result = res
                break
              else:
                res += datalen
                rstream.buffer.shift(datalen)
          await rstream.buffer.wait()
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym20710046 = consume_20710044
  {.push, stackTrace: off.}
  proc consume_continue_20710045(udata`gensym20710047: pointer = nil) {.closure,
      gcsafe.} =
    try:
      if not (nameIterVar`gensym20710046.finished()):
        var next`gensym20710048 = nameIterVar`gensym20710046()
        while (not next`gensym20710048.isNil()) and
            next`gensym20710048.finished():
          next`gensym20710048 = nameIterVar`gensym20710046()
          if nameIterVar`gensym20710046.finished():
            break
        if next`gensym20710048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20710049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20710049 % "consume")
        else:
          {.gcsafe.}:
            next`gensym20710048.addCallback(consume_continue_20710045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20710050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20710050
      else:
        chronosInternalRetFuture.fail(exc`gensym20710050)

  consume_continue_20710045()
  {.pop.}
  return chronosInternalRetFuture

proc write*(wstream: AsyncStreamWriter; pbytes: pointer; nbytes: int): Future[void] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("write")
  iterator write_20780044(): FutureBase {.closure.} =
    ## Write sequence of bytes pointed by ``pbytes`` of length ``nbytes`` to
    ## writer stream ``wstream``.
    ## 
    ## ``nbytes` must be more then zero.
    if not wstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if nbytes <= 0:
      raise newAsyncStreamIncorrectError("Zero length message")
    if isNil(wstream.wsource):
      var res: int
      try:
        res = await write(wstream.tsource, pbytes, nbytes)
      except CancelledError:
        raise
      except CatchableError as exc:
        raise newAsyncStreamWriteError(exc)
      if res != nbytes:
        raise newAsyncStreamIncompleteError()
    else:
      if isNil(wstream.writerLoop):
        await write(wstream.wsource, pbytes, nbytes)
      else:
        var item = WriteItem(kind: Pointer)
        item.data1 = pbytes
        item.size = nbytes
        item.future = newFuture[void]("async.stream.write(pointer)")
        await wstream.queue.put(item)
        try:
          await item.future
        except CancelledError:
          raise
        except:
          raise newAsyncStreamWriteError(item.future.error)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym20780046 = write_20780044
  {.push, stackTrace: off.}
  proc write_continue_20780045(udata`gensym20780047: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym20780046.finished()):
        var next`gensym20780048 = nameIterVar`gensym20780046()
        while (not next`gensym20780048.isNil()) and
            next`gensym20780048.finished():
          next`gensym20780048 = nameIterVar`gensym20780046()
          if nameIterVar`gensym20780046.finished():
            break
        if next`gensym20780048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20780049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20780049 % "write")
        else:
          {.gcsafe.}:
            next`gensym20780048.addCallback(write_continue_20780045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20780050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20780050
      else:
        chronosInternalRetFuture.fail(exc`gensym20780050)

  write_continue_20780045()
  {.pop.}
  return chronosInternalRetFuture

proc write*(wstream: AsyncStreamWriter; sbytes: seq[byte]; msglen = -1): Future[void] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("write")
  iterator write_20960044(): FutureBase {.closure.} =
    ## Write sequence of bytes ``sbytes`` of length ``msglen`` to writer
    ## stream ``wstream``.
    ## 
    ## Sequence of bytes ``sbytes`` must not be zero-length.
    ## 
    ## If ``msglen < 0`` whole sequence ``sbytes`` will be writen to stream.
    ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
    ## stream.
    let length = if msglen <= 0:
      len(sbytes) else:
      min(msglen, len(sbytes))
    if not wstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if length <= 0:
      raise newAsyncStreamIncorrectError("Zero length message")
    if isNil(wstream.wsource):
      var res: int
      try:
        res = await write(wstream.tsource, sbytes, msglen)
      except CancelledError:
        raise
      except CatchableError as exc:
        raise newAsyncStreamWriteError(exc)
      if res != length:
        raise newAsyncStreamIncompleteError()
    else:
      if isNil(wstream.writerLoop):
        await write(wstream.wsource, sbytes, msglen)
      else:
        var item = WriteItem(kind: Sequence)
        if not isLiteral(sbytes):
          shallowCopy(item.data2, sbytes)
        else:
          item.data2 = sbytes
        item.size = length
        item.future = newFuture[void]("async.stream.write(seq)")
        await wstream.queue.put(item)
        try:
          await item.future
        except CancelledError:
          raise
        except:
          raise newAsyncStreamWriteError(item.future.error)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym20960046 = write_20960044
  {.push, stackTrace: off.}
  proc write_continue_20960045(udata`gensym20960047: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym20960046.finished()):
        var next`gensym20960048 = nameIterVar`gensym20960046()
        while (not next`gensym20960048.isNil()) and
            next`gensym20960048.finished():
          next`gensym20960048 = nameIterVar`gensym20960046()
          if nameIterVar`gensym20960046.finished():
            break
        if next`gensym20960048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym20960049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym20960049 % "write")
        else:
          {.gcsafe.}:
            next`gensym20960048.addCallback(write_continue_20960045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym20960050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym20960050
      else:
        chronosInternalRetFuture.fail(exc`gensym20960050)

  write_continue_20960045()
  {.pop.}
  return chronosInternalRetFuture

proc write*(wstream: AsyncStreamWriter; sbytes: string; msglen = -1): Future[void] {.
    stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("write")
  iterator write_21115044(): FutureBase {.closure.} =
    ## Write string ``sbytes`` of length ``msglen`` to writer stream ``wstream``.
    ## 
    ## String ``sbytes`` must not be zero-length.
    ## 
    ## If ``msglen < 0`` whole string ``sbytes`` will be writen to stream.
    ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
    ## stream.
    let length = if msglen <= 0:
      len(sbytes) else:
      min(msglen, len(sbytes))
    if not wstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if length <= 0:
      raise newAsyncStreamIncorrectError("Zero length message")
    if isNil(wstream.wsource):
      var res: int
      try:
        res = await write(wstream.tsource, sbytes, msglen)
      except CancelledError:
        raise
      except CatchableError as exc:
        raise newAsyncStreamWriteError(exc)
      if res != length:
        raise newAsyncStreamIncompleteError()
    else:
      if isNil(wstream.writerLoop):
        await write(wstream.wsource, sbytes, msglen)
      else:
        var item = WriteItem(kind: String)
        if not isLiteral(sbytes):
          shallowCopy(item.data3, sbytes)
        else:
          item.data3 = sbytes
        item.size = length
        item.future = newFuture[void]("async.stream.write(string)")
        await wstream.queue.put(item)
        try:
          await item.future
        except CancelledError:
          raise
        except:
          raise newAsyncStreamWriteError(item.future.error)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym21115046 = write_21115044
  {.push, stackTrace: off.}
  proc write_continue_21115045(udata`gensym21115047: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym21115046.finished()):
        var next`gensym21115048 = nameIterVar`gensym21115046()
        while (not next`gensym21115048.isNil()) and
            next`gensym21115048.finished():
          next`gensym21115048 = nameIterVar`gensym21115046()
          if nameIterVar`gensym21115046.finished():
            break
        if next`gensym21115048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym21115049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym21115049 % "write")
        else:
          {.gcsafe.}:
            next`gensym21115048.addCallback(write_continue_21115045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym21115050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym21115050
      else:
        chronosInternalRetFuture.fail(exc`gensym21115050)

  write_continue_21115045()
  {.pop.}
  return chronosInternalRetFuture

proc finish*(wstream: AsyncStreamWriter): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("finish")
  iterator finish_21200044(): FutureBase {.closure.} =
    ## Finish write stream ``wstream``.
    if not wstream.running():
      raise newAsyncStreamIncorrectError("Incorrect stream state")
    if not isNil(wstream.wsource):
      if isNil(wstream.writerLoop):
        await wstream.wsource.finish()
      else:
        var item = WriteItem(kind: Pointer)
        item.size = 0
        item.future = newFuture[void]("async.stream.finish")
        await wstream.queue.put(item)
        try:
          await item.future
        except CancelledError:
          raise
        except:
          raise newAsyncStreamWriteError(item.future.error)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym21200046 = finish_21200044
  {.push, stackTrace: off.}
  proc finish_continue_21200045(udata`gensym21200047: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym21200046.finished()):
        var next`gensym21200048 = nameIterVar`gensym21200046()
        while (not next`gensym21200048.isNil()) and
            next`gensym21200048.finished():
          next`gensym21200048 = nameIterVar`gensym21200046()
          if nameIterVar`gensym21200046.finished():
            break
        if next`gensym21200048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym21200049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym21200049 % "finish")
        else:
          {.gcsafe.}:
            next`gensym21200048.addCallback(finish_continue_21200045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym21200050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym21200050
      else:
        chronosInternalRetFuture.fail(exc`gensym21200050)

  finish_continue_21200045()
  {.pop.}
  return chronosInternalRetFuture

proc chunkedReadLoop(stream: AsyncStreamReader): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("chunkedReadLoop")
  iterator chunkedReadLoop_21355026(): FutureBase {.closure.} =
    var rstream = cast[ChunkedStreamReader](stream)
    var buffer = newSeq[byte](1024)
    rstream.state = AsyncStreamState.Running
    try:
      while true:
        var ruFut1 = awaitne rstream.rsource.readUntil(addr buffer[0], 1024, CRLF)
        if ruFut1.failed():
          rstream.error = ruFut1.error
          rstream.state = AsyncStreamState.Error
          break
        let length = ruFut1.read()
        var chunksize = getChunkSize(buffer.toOpenArray(0, length - len(CRLF) - 1))
        if chunksize == 0xFFFFFFFFFFFFFFFF'u64:
          rstream.error = newProtocolError()
          rstream.state = AsyncStreamState.Error
          break
        elif chunksize > 0'u64:
          while chunksize > 0'u64:
            let toRead = min(int(chunksize), rstream.buffer.bufferLen())
            var reFut2 = awaitne rstream.rsource.readExactly(
                rstream.buffer.getBuffer(), toRead)
            if reFut2.failed():
              rstream.error = reFut2.error
              rstream.state = AsyncStreamState.Error
              break
            rstream.buffer.update(toRead)
            await rstream.buffer.transfer()
            chunksize = chunksize - uint64(toRead)
          if rstream.state != AsyncStreamState.Running:
            break
          var reFut3 = awaitne rstream.rsource.readExactly(addr buffer[0], 2)
          if reFut3.failed():
            rstream.error = reFut3.error
            rstream.state = AsyncStreamState.Error
            break
          if buffer[0] != CRLF[0] or buffer[1] != CRLF[1]:
            rstream.error = newProtocolError()
            rstream.state = AsyncStreamState.Error
            break
        else:
          var ruFut4 = awaitne rstream.rsource.readUntil(addr buffer[0], len(buffer),
              CRLF)
          if ruFut4.failed():
            rstream.error = ruFut4.error
            rstream.state = AsyncStreamState.Error
            break
          rstream.state = AsyncStreamState.Finished
          await rstream.buffer.transfer()
          break
    except CancelledError:
      rstream.state = AsyncStreamState.Stopped
    finally:
      if rstream.state in {AsyncStreamState.Stopped, AsyncStreamState.Error}:
        rstream.buffer.forget()
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym21355028 = chunkedReadLoop_21355026
  {.push, stackTrace: off.}
  proc chunkedReadLoop_continue_21355027(udata`gensym21355029: pointer = nil) {.
      closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym21355028.finished()):
        var next`gensym21355030 = nameIterVar`gensym21355028()
        while (not next`gensym21355030.isNil()) and
            next`gensym21355030.finished():
          next`gensym21355030 = nameIterVar`gensym21355028()
          if nameIterVar`gensym21355028.finished():
            break
        if next`gensym21355030 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym21355031 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError,
                              msg`gensym21355031 % "chunkedReadLoop")
        else:
          {.gcsafe.}:
            next`gensym21355030.addCallback(chunkedReadLoop_continue_21355027)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym21355032:
      if chronosInternalRetFuture.finished():
        raise exc`gensym21355032
      else:
        chronosInternalRetFuture.fail(exc`gensym21355032)

  chunkedReadLoop_continue_21355027()
  {.pop.}
  return chronosInternalRetFuture

proc chunkedWriteLoop(stream: AsyncStreamWriter): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("chunkedWriteLoop")
  iterator chunkedWriteLoop_21470044(): FutureBase {.closure.} =
    var wstream = cast[ChunkedStreamWriter](stream)
    var buffer: array[16, byte]
    var wFut1, wFut2: Future[void]
    var error: ref Exception
    wstream.state = AsyncStreamState.Running
    try:
      while true:
        var item = await wstream.queue.get()
        if item.size > 0:
          let length = setChunkSize(buffer, int64(item.size))
          wFut1 = awaitne wstream.wsource.write(addr buffer[0], length)
          if wFut1.failed():
            error = wFut1.error
            item.future.fail(error)
            continue
          if item.kind == Pointer:
            wFut2 = awaitne wstream.wsource.write(item.data1, item.size)
          elif item.kind == Sequence:
            wFut2 = awaitne wstream.wsource.write(addr item.data2[0], item.size)
          elif item.kind == String:
            wFut2 = awaitne wstream.wsource.write(addr item.data3[0], item.size)
          if wFut2.failed():
            error = wFut2.error
            item.future.fail(error)
            continue
          var wFut3 = awaitne wstream.wsource.write(CRLF)
          if wFut3.failed():
            error = wFut3.error
            item.future.fail(error)
            continue
          item.future.complete()
        else:
          let length = setChunkSize(buffer, 0'i64)
          wFut1 = awaitne wstream.wsource.write(addr buffer[0], length)
          if wFut1.failed():
            error = wFut1.error
            item.future.fail(error)
            break
          wFut2 = awaitne wstream.wsource.write(CRLF)
          if wFut2.failed():
            error = wFut2.error
            item.future.fail(error)
            break
          item.future.complete()
          wstream.state = AsyncStreamState.Finished
          break
    except CancelledError:
      wstream.state = AsyncStreamState.Stopped
    finally:
      if wstream.state == AsyncStreamState.Stopped:
        while len(wstream.queue) > 0:
          let item = wstream.queue.popFirstNoWait()
          if not (item.future.finished()):
            item.future.complete()
      elif wstream.state == AsyncStreamState.Error:
        while len(wstream.queue) > 0:
          let item = wstream.queue.popFirstNoWait()
          if not (item.future.finished()):
            if not isNil(error):
              item.future.fail(error)
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym21470046 = chunkedWriteLoop_21470044
  {.push, stackTrace: off.}
  proc chunkedWriteLoop_continue_21470045(udata`gensym21470047: pointer = nil) {.
      closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym21470046.finished()):
        var next`gensym21470048 = nameIterVar`gensym21470046()
        while (not next`gensym21470048.isNil()) and
            next`gensym21470048.finished():
          next`gensym21470048 = nameIterVar`gensym21470046()
          if nameIterVar`gensym21470046.finished():
            break
        if next`gensym21470048 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym21470049 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError,
                              msg`gensym21470049 % "chunkedWriteLoop")
        else:
          {.gcsafe.}:
            next`gensym21470048.addCallback(chunkedWriteLoop_continue_21470045)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym21470050:
      if chronosInternalRetFuture.finished():
        raise exc`gensym21470050
      else:
        chronosInternalRetFuture.fail(exc`gensym21470050)

  chunkedWriteLoop_continue_21470045()
  {.pop.}
  return chronosInternalRetFuture

proc bufferMoreDataAsync(s: AsyncInputStream): Future[bool] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[bool]("bufferMoreDataAsync")
  iterator bufferMoreDataAsync_23795020(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: bool
    {.pop.}
    complete(chronosInternalRetFuture, false)
    return nil
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym23795022 = bufferMoreDataAsync_23795020
  {.push, stackTrace: off.}
  proc bufferMoreDataAsync_continue_23795021(udata`gensym23795023: pointer = nil) {.
      closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym23795022.finished()):
        var next`gensym23795024 = nameIterVar`gensym23795022()
        while (not next`gensym23795024.isNil()) and
            next`gensym23795024.finished():
          next`gensym23795024 = nameIterVar`gensym23795022()
          if nameIterVar`gensym23795022.finished():
            break
        if next`gensym23795024 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym23795025 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError,
                              msg`gensym23795025 % "bufferMoreDataAsync")
        else:
          {.gcsafe.}:
            next`gensym23795024.addCallback(bufferMoreDataAsync_continue_23795021)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym23795026:
      if chronosInternalRetFuture.finished():
        raise exc`gensym23795026
      else:
        chronosInternalRetFuture.fail(exc`gensym23795026)

  bufferMoreDataAsync_continue_23795021()
  {.pop.}
  return chronosInternalRetFuture

proc close*[T; S: Stream[T]](s: S): Future[void] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[void]("close")
  iterator close_25785086(): FutureBase {.closure.} =
    s.eof = true
    complete(chronosInternalRetFuture)

  var nameIterVar`gensym25785088 = close_25785086
  {.push, stackTrace: off.}
  proc close_continue_25785087(udata`gensym25785089: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym25785088.finished()):
        var next`gensym25785090 = nameIterVar`gensym25785088()
        while (not next`gensym25785090.isNil()) and
            next`gensym25785090.finished():
          next`gensym25785090 = nameIterVar`gensym25785088()
          if nameIterVar`gensym25785088.finished():
            break
        if next`gensym25785090 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym25785091 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym25785091 % "close")
        else:
          {.gcsafe.}:
            next`gensym25785090.addCallback(close_continue_25785087)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym25785092:
      if chronosInternalRetFuture.finished():
        raise exc`gensym25785092
      else:
        chronosInternalRetFuture.fail(exc`gensym25785092)

  close_continue_25785087()
  {.pop.}
  return chronosInternalRetFuture

proc get[T](p: Pushable[T]): Future[T] {.stackTrace: off.} =
  var chronosInternalRetFuture = newFuture[T]("get")
  iterator get_25800179(): FutureBase {.closure.} =
    {.push, warning[resultshadowed]: off.}
    var result: T
    {.pop.}
    result = await p.queue.popFirst()
    if result == p.eofTag:
      p.eof = true
    complete(chronosInternalRetFuture, result)

  var nameIterVar`gensym25800181 = get_25800179
  {.push, stackTrace: off.}
  proc get_continue_25800180(udata`gensym25800182: pointer = nil) {.closure, gcsafe.} =
    try:
      if not (nameIterVar`gensym25800181.finished()):
        var next`gensym25800183 = nameIterVar`gensym25800181()
        while (not next`gensym25800183.isNil()) and
            next`gensym25800183.finished():
          next`gensym25800183 = nameIterVar`gensym25800181()
          if nameIterVar`gensym25800181.finished():
            break
        if next`gensym25800183 == nil:
          if not (chronosInternalRetFuture.finished()):
            let msg`gensym25800184 = "Async procedure ($1) yielded `nil`, " &
                "are you await\'ing a `nil` Future?"
            raise newException(AssertionError, msg`gensym25800184 % "get")
        else:
          {.gcsafe.}:
            next`gensym25800183.addCallback(get_continue_25800180)
    except CancelledError:
      chronosInternalRetFuture.cancel()
    except CatchableError as exc`gensym25800185:
      if chronosInternalRetFuture.finished():
        raise exc`gensym25800185
      else:
        chronosInternalRetFuture.fail(exc`gensym25800185)

  get_continue_25800180()
  {.pop.}
  return chronosInternalRetFuture

