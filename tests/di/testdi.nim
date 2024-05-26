{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import ../helpers
import ../../di/di

type
  MyInterface = ref object of RootObj
  MyImplementation = ref object of MyInterface
  AnotherImplementation = ref object of MyInterface

  MyObject = object

method doSomething(obj: MyInterface) {.base.} = discard

method doSomething(obj: MyImplementation) =
  echo "MyImplementation doing something!"

method doSomething(obj: AnotherImplementation) =
  echo "AnotherImplementation doing something!"

proc provideMyImplementation(): MyInterface =
  MyImplementation()

proc provideAnotherImplementation(): MyInterface =
  AnotherImplementation()

suite "DI":

  asyncTest "DI":
    let container = Container()
    register[MyInterface](container, provideMyImplementation, "myImplementation")
    register[MyInterface](container, provideAnotherImplementation, "anotherImplementation")

    let myImplementation = resolve[MyInterface](container, "anotherImplementation")
    myImplementation.doSomething()