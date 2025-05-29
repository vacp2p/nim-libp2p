# Table of Contents
- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Script](#script)
- [Examples](#examples)

# Introduction
This is a libp2p-backed daemon wrapping the functionalities of go-libp2p for use in Nim. <br>
For more information about the go daemon, check out [this repository](https://github.com/libp2p/go-libp2p-daemon).
> **Required only** for running the tests.

# Prerequisites
Go with version `1.16.0`
> You will *likely* be able to build `go-libp2p-daemon` with different Go versions, but **they haven't been tested**.

# Installation
Run the build script while having the `go` command pointing to the correct Go version.
```sh
./scripts/build_p2pd.sh
```
`build_p2pd.sh` will not rebuild unless needed. If you already have the newest binary and you want to force the rebuild, use:
```sh
./scripts/build_p2pd.sh -f
```
Or:
```sh
./scripts/build_p2pd.sh --force
```

If everything goes correctly, the binary (`p2pd`) should be built and placed in the `$GOPATH/bin` directory.
If you're having issues, head into [our discord](https://discord.com/channels/864066763682218004/1115526869769535629) and ask for assistance.

After successfully building the binary, remember to add it to your path so it can be found. You can do that by running:
```sh
export PATH="$PATH:$HOME/go/bin"
```
> **Tip:** To make this change permanent, add the command above to your `.bashrc` file.

# Examples
Examples can be found in the [examples folder](https://github.com/status-im/nim-libp2p/tree/readme/examples/go-daemon)


