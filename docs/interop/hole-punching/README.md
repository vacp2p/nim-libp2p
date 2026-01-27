[← Docs Index](../../README.md)

# Hole Punching Interop Tests

This is how to run the interop test plans for hole punching locally

0. [Install `npm`](https://docs.npmjs.com/downloading-and-installing-node-js-and-npm)

1. Build the nim docker image (obs: needs to be rebuilt every time you change the nim file)

```sh
# run the following on the root of nim-libp2p
sudo docker build -t nim-libp2p-head -f interop/hole-punching/Dockerfile .
```

2. Clone [test-plans](https://github.com/libp2p/test-plans)

```sh
git clone https://github.com/libp2p/test-plans
```

3. Build the test plans docker images

```sh
cd /your/path/to/test-plans/hole-punch-interop
npm install
# sudo is only used because of docker (you may not need it)
make
```

4. Run test plans using the previously built nim docker image

```sh
cd /your/path/to/test-plans/hole-punch-interop
npm run test -- --extra-version=/your/path/to/nim-libp2p/interop/hole-punching/version.json --name-filter=nim-libp2p-head
```
