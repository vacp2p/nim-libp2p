import deques, sequtils
import chronos, stew/byteutils

var queue = initDeque[string]()

queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")
queue.addLast("Hello")

echo queue.mapIt($it & " World!")
