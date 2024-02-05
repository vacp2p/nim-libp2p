# Table of Contents
- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Script (Recommended)](#script-recommended)
  - [Manual](#manual)
- [Usage](#usage)
  - [Example](#example)
  - [Getting Started](#getting-started)

# Introduction
This is a libp2p-backed daemon wrapping the functionalities of go-libp2p for use in Nim. <br>
For more information about the go daemon, check out [this repository](https://github.com/libp2p/go-libp2p-daemon).

# Prerequisites
Go with version `1.15.15`.
> You will *likely* be able to build `go-libp2p-daemon` with different Go versions, but **they haven't been tested**.

# Installation
Follow one of the methods below:

## Script (Recommended)
Run the build script while having the `go` command pointing to the correct Go version.
We recommend using `1.15.15`, as previously stated.
```sh
./scripts/build_p2pd.sh
```
If everything goes correctly, the binary (`p2pd`) should be built and placed in the correct directory.
If you find any issues, please head into our discord and ask for our asistance.

After successfully building the binary, remember to add it to your path so it can be found. You can do that by running:
```sh
export PATH="$PATH:$HOME/go/bin"
```
> **Tip:** To make this change permanent, add the command above to your `.bashrc` file.

## Manual
```sh
# clone and install dependencies
git clone https://github.com/status-im/nim-libp2p
cd nim-libp2p
nimble install

# perform unit tests
nimble test

# update the git submodule to install the go daemon 
git submodule update --init --recursive
go version
git clone https://github.com/libp2p/go-libp2p-daemon
cd go-libp2p-daemon
git checkout v0.0.1
go install ./...
cd ..
```

# Usage 

## Example
Examples can be found in the [examples folder](https://github.com/status-im/nim-libp2p/tree/readme/examples/go-daemon)

## Getting Started
Try out the chat example. Full code can be found [here](https://github.com/status-im/nim-libp2p/blob/master/examples/chat.nim):

```bash
nim c -r --threads:on examples/directchat.nim
```

This will output a peer ID such as `QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu` which you can use in another instance to connect to it.

```bash
./examples/directchat
/connect QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu
```

You can now chat between the instances!

![Chat example](https://imgur.com/caYRu8K.gif)



