when not declared(newSeqUninit):
  # newSeqUninit template avoids deprecated errors
  # for newSeqUninitialized in nim > 2.2
  template newSeqUninit*[T: byte](len: Natural): seq[byte] =
    newSeqUninitialized[byte](len)
