import unittest2
import nimcrypto/utils
import ../libp2p/multihash

when defined(nimHasUsed): {.used.}

const
  RustTestVectors = [
    [
      "sha1",
      "beep boop",
      "11147C8357577F51D4F0A8D393AA1AAAFB28863D9421"
    ],
    [
      "sha2-256",
      "helloworld",
      "1220936A185CAAA266BB9CBE981E9E05CB78CD732B0B3280EB944412BB6F8F8F07AF",
    ],
    [
      "sha2-256",
      "beep boop",
      "122090EA688E275D580567325032492B597BC77221C62493E76330B85DDDA191EF7C",
    ],
    [
      "sha2-512",
      "hello world",
      """1340309ECC489C12D6EB4CC40F50C902F2B4D0ED77EE511A7C7A9BCD3CA86D4C
         D86F989DD35BC5FF499670DA34255B45B0CFD830E81F605DCF7DC5542E93AE9C
         D76F"""
    ],
    [
      "sha3-224",
      "hello world",
      "171CDFB7F18C77E928BB56FAEB2DA27291BD790BC1045CDE45F3210BB6C5"
    ],
    [
      "sha3-256",
      "hello world",
      "1620644BCC7E564373040999AAC89E7622F3CA71FBA1D972FD94A31C3BFBF24E3938"
    ],
    [
      "sha3-384",
      "hello world",
      """153083BFF28DDE1B1BF5810071C6643C08E5B05BDB836EFFD70B403EA8EA0A63
         4DC4997EB1053AA3593F590F9C63630DD90B"""
    ],
    [
      "sha3-512",
      "hello world",
      """1440840006653E9AC9E95117A15C915CAAB81662918E925DE9E004F774FF82D7
         079A40D4D27B1B372657C61D46D470304C88C788B3A4527AD074D1DCCBEE5DBA
         A99A"""
    ],
    [
      "keccak-224",
      "hello world",
      "1A1C25F3ECFEBABE99686282F57F5C9E1F18244CFEE2813D33F955AAE568"
    ],
    [
      "keccak-256",
      "hello world",
      "1B2047173285A8D7341E5E972FC677286384F802F8EF42A5EC5F03BBFA254CB01FAD"
    ],
    [
      "keccak-384",
      "hello world",
      """1C3065FC99339A2A40E99D3C40D695B22F278853CA0F925CDE4254BCAE5E22ECE4
         7E6441F91B6568425ADC9D95B0072EB49F"""
    ],
    [
      "keccak-512",
      "hello world",
      """1D403EE2B40047B8060F68C67242175660F4174D0AF5C01D47168EC20ED619B0
         B7C42181F40AA1046F39E2EF9EFC6910782A998E0013D172458957957FAC9405
         B67D"""
    ]
  ]


suite "MultiHash test suite":
  test "rust-multihash test vectors":
    for item in RustTestVectors:
      var msg = item[1]
      var bmsg = cast[seq[byte]](msg)
      var mh1 = MultiHash.digest(item[0], bmsg).get()
      var mh2 = MultiHash.init(stripSpaces(item[2])).get()
      check:
        hex(mh1) == stripSpaces(item[2])
        hex(mh1) == hex(mh2)
        mh1 == mh2
