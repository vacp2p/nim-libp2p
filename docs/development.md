# Development

Clone the repository and install the dependencies:
```sh
git clone https://github.com/vacp2p/nim-libp2p
cd nim-libp2p
nimble install -dy
```
You can use `nix develop` to start a shell with Nim and Nimble.

nimble 0.20.1 is required for running `nimble test`. At time of writing, this is not available in nixpkgs: If using `nix develop`, follow up with `nimble install nimble`, and use that (typically `~/.nimble/bin/nimble`).


## Getting Started
Try out the chat example. Full code can be found [here](https://github.com/vacp2p/nim-libp2p/blob/master/examples/directchat.nim):

```bash
nim c -r --threads:on examples/directchat.nim
```

This will output a peer ID such as `QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu` which you can use in another instance to connect to it.

```bash
./examples/directchat
/connect QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu # change this hash by the hash you were given
```

You can now chat between the instances!

![Chat example](https://imgur.com/caYRu8K.gif)

## Testing
Run unit tests:
```sh
# run all the unit tests
nimble test

# run tests matching a path substring:
# - Directory name: "transports" matches all tests in transports/
# - Partial filename: "quic" matches test_quic.nim, test_quic_stream.nim, etc.
# - Exact filename: "test_ws.nim" matches only that specific file
# - Full path: "libp2p/transports/test_tcp" matches libp2p/transports/test_tcp.nim
nimble testpath quic
nimble testpath transports/test_ws
nimble testpath mix
# etc ...

# run specific test suites
nimble testmultiformatexts
nimble testintegration
```

For faster iteration during development, you can bypass nimble overhead by compiling the test file directly:

```sh
# compile and run all tests
nim c -r tests/test_all.nim

# compile and run tests matching a path substring
nim c -r -d:path=quic tests/test_all.nim
nim c -r -d:path=transports/test_ws tests/test_all.nim
nim c -r -d:path=mix tests/test_all.nim

# compile and run specific test file
nim c -r tests/tools/test_multiaddress.nim
```

## Formatting code

Code should be formatted with [nph](https://github.com/arnetheduck/nph). 

Do `nimble install nph@v0.6.1` once to install nph, then `nimble format` (or `nph ./. *.nim`) to format code.
