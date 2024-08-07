import stew/results, options

proc assertIsOk*[T, E](res: Result[T, E]) =
  assert res.isOk, res.error

proc assertIsErr*[T, E](res: Result[T, E], error: Option[E] = E.none()) =
  assert res.isErr, "Result was \"Err\" but expected \"Ok\""
  if error.isSome():
    assert res.error == error.get(),
      "Result was \"" & res.error & "\" but expected \"" & error.get() & "\""
