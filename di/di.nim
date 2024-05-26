import typetraits
import tables

type
  BindingKey = tuple[typeName: string, qualifier: string]

  Container* = ref object
     bindings*: Table[BindingKey,  proc(): RootRef {.gcsafe, raises: [].}]

  BindingNotFoundError* = object of CatchableError

proc register*[T](c: Container, implementation: proc(): T  {.gcsafe, raises: [].}, qualifier: string = "") =
  let key: BindingKey = (name(T), qualifier)
  proc p(): RootRef =
    let o: RootRef = implementation()
    return o
  c.bindings[key] = p

proc resolve*[T](c: Container, qualifier: string = ""): T {.raises: [BindingNotFoundError]} =
  let key: BindingKey = (name(T), qualifier)
  try:
    return cast[T](c.bindings[key]())
  except KeyError:
    raise newException(BindingNotFoundError, "Type not bound: " & name(T))