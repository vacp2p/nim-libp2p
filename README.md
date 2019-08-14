# nim-libp2p

[![Build Status](https://travis-ci.org/status-im/nim-libp2p.svg?branch=master)](https://travis-ci.org/status-im/nim-libp2p)
[![Build status](https://ci.appveyor.com/api/projects/status/pqgif5bcie6cp3wi/branch/master?svg=true)](https://ci.appveyor.com/project/nimbus/nim-libp2p/branch/master)

## Introduction

An implementation of [libp2p](https://libp2p.io/) in Nim, as a wrapper of the [Libp2p Go daemon](https://github.com/libp2p/go-libp2p).

Note that you need Go 1.12+ for the below instructions to work!

Install dependencies and run tests with:

```bash
nimble install
nimble test
git submodule update --init --recursive
go version
git clone https://github.com/libp2p/go-libp2p-daemon
cd go-libp2p-daemon
git checkout v0.0.1
go install ./...
cd ..
```

Try out the chat example:

```bash
nim c -r --threads:on examples\chat.nim
```

This will output a peer ID such as `QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu` which you can use in another instance to connect to it.

```bash
./example/chat
/connect QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu
```

You can now chat between the instances!

![Chat example](https://imgur.com/caYRu8K.gif)

## API

Coming soon...

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.
