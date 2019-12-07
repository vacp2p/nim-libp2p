import testvarint, testbase32, testbase58, testbase64
import testrsa, testecnist, tested25519, testsecp256k1, testcrypto
import testmultibase, testmultihash, testmultiaddress, testcid, testpeer

import testtransport, 
       testmultistream, 
       testbufferstream, 
       testidentify, 
       testswitch,
       testpeerinfo,
       pubsub/testpubsub,
       # TODO: placing this before pubsub tests, 
       # breaks some flood and gossip tests - no idea why
       testmplex
