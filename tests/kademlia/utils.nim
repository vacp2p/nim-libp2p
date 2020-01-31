import options, tables
import chronos
import ../../libp2p/standard_setup
export standard_setup

proc generateNodes*(num: Natural): seq[Switch] =
  for i in 0..<num:
    result.add(newKadSwitch())
