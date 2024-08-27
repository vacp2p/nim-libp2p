# Sourced from https://forum.nim-lang.org/t/9255#60617

import posix

type Instr {.union.} = object
  bytes: array[8, byte]
  value: uint64

proc mockImpl*(target, replacement: pointer) =
  # YOLO who needs alignment
  #doAssert (cast[ByteAddress](target) and ByteAddress(0x07)) == 0
  var page = cast[pointer](cast[ByteAddress](target) and (not 0xfff))
  doAssert mprotect(page, 4096, PROT_WRITE or PROT_EXEC) == 0
  let rel = cast[ByteAddress](replacement) - cast[ByteAddress](target) - 5
  var instr = Instr(
    bytes: [
      0xe9.byte,
      (rel shr 0).byte,
      (rel shr 8).byte,
      (rel shr 16).byte,
      (rel shr 24).byte,
      0,
      0,
      0,
    ]
  )
  cast[ptr uint64](target)[] = instr.value
  doAssert mprotect(page, 4096, PROT_EXEC) == 0

# Note: Requires manual cleanup
# Usage Example:
# proc helloWorld(): string = 
#   "Hello, World!"
#
# echo helloWorld() # "Hello, World!"
#
# let backup = helloWorld
# mock(helloWorld):
#   proc mockedHellWorld(): string =
#     "Mocked Hello, World!"
#   mockedHellWorld
#
# echo helloWorld() # "Mocked Hello, World!"
# 
# mock(helloWorld):
#   backup
template mock*(target, replacement: untyped): untyped =
  mockImpl(cast[pointer](target), cast[pointer](replacement))
