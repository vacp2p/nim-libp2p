import testutils/unittests

template xsuite*(name: string, body: untyped) =
  discard

template suitex*(name: string, body: untyped) =
  discard

template xprocSuite*(name: string, body: untyped) =
  discard

template procSuitex*(name: string, body: untyped) =
  discard

template xtest*(name: string, body: untyped) =
  test name:
    skip()

template testx*(name: string, body: untyped) =
  test name:
    skip()

template xasyncTest*(name: string, body: untyped) =
  test name:
    skip()

template asyncTestx*(name: string, body: untyped) =
  test name:
    skip()
