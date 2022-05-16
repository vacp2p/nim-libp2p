## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
when defined(nimHasUsed): {.used.}

import unittest2
import stublogger
import ../libp2p/crypto/crypto
import nimcrypto/utils

let rng = newRng()

const ECDSA_PrivateKey = """
  080312793077020101042070896381749FF6B30381C045F627C68C3062749BB53CB13
  11FA07A7AEAB0A225A00A06082A8648CE3D030107A14403420004B17DAFF40C3221A5
  0889A3FA9BB9DA4996AA1FE80D37358FBC6C88D89CD65738B4738C07CFD42F55293EB
  3A56DB224EDCD36E51076F43A63203F8936D868EF18
"""
const ECDSA_PublicKey = """
  0803125B3059301306072A8648CE3D020106082A8648CE3D03010703420004B17DAFF
  40C3221A50889A3FA9BB9DA4996AA1FE80D37358FBC6C88D89CD65738B4738C07CFD4
  2F55293EB3A56DB224EDCD36E51076F43A63203F8936D868EF18
"""
const SECP256k1_PrivateKey = """
  080212209A0F994F5022D9D7B67ACEB26AA4D9F29B2628DBDCC28597469CB0049B6AB
  348
"""
const SECP256k1_PublicKey = """
  08021221039111FA29B374FE94B885408C45DF4647D09438C6E1F91F9B277A96CADD0
  8A2B8
"""
const ED25519_PrivateKey = """
  08011240E1BFE38E35F9669CE77F6BE1A551560896B59A3F510537205F3AC1EDAD421
  601C9D5C25AA2FC61B950976D6E5EC26425F8D4BFFE17169A4DE5A246B7154CB2B5
"""
const ED25519_PublicKey = """
  08011220C9D5C25AA2FC61B950976D6E5EC26425F8D4BFFE17169A4DE5A246B7154CB
  2B5
"""
const RSA_PrivateKey = """
  080012E80D308206E40201000282018100B5F2CABD05BE70474B262A2715B8C4FE74C
  6F628757FADB3F4815881CD9F8D3D2583757DF178B9BDCB207EB183A260934E6580C9
  3B75789ACADAC13C9DD5A21A6BEDC4845A76D32F61F37C69B2C0E9D1161459FB1C93C
  E13E3EA0436B82086DF4EC95860D910D32B134610C20E84834A4B9A40C5B4D6FB0732
  FF5332D8050221DA5101639044B6E2B18659E242FEEE58F4FF90BC9BEFF740E22C1A5
  02774E4A0B103F750B829D6B1034908DB8338374EE2EF972A0E760DA9CC42F7D160CB
  33C4918308389CD7EF98D58378BB8CF8F8314131C6654903C704EE6BC069B223A39DE
  1CF1D5B0E34CE02522CFADF24AAF526445F7673CDE19F62C6D70266D1F7D03F98F9BD
  69C1BC78662BB9F52D90C2D1841680A9E6528E52BF2F83B84EC73D819240029A677F5
  AD8EF963843D36DB556B214E09A72B589FA139AFAED0EE5409AFFCAAEFC06329E2945
  A727E1AED64C1935F17F6F1E8FDD1B4AE69CACC3DAD8153059B5775A0A3B0EF38E3A1
  8CFE3DB4338F53F03B6CA30E729A5EC510C68CE662902030100010282018012759C7E
  0AEC24460768CAD4064F25A54F41B44DAC8614A07249012AC22AD2D08652CD03C710E
  17F50F16E09227AC1E3900B9A425046FDC26E9C3D08A256BF4880F4B18060113821D1
  853B7519CE9AAA3CDC39B8D1506992F9078FFFE134639A9A4AB12DBA380BC48E0308C
  63764D8511C547D07D1EE11AFCC4BBD2C266073B3ED8B5461BE8C4A25BBAF0EC576D8
  9863EC0F55A6DD073E8595ACB5CAB60614FFFC95936CDC125A96C0E792FF7A53A4C0D
  B2345A9DDA7BA81249912BD6A5D9355CD41A73B0E2A8D76ED7BB4D5B9AD98E5DD72CC
  0C01D55CF89ADC4DE4D7457BFFC88F7DBE0E0C77725920DFF7B37B05E47BF7E930584
  D8E3FD054189282EF5EF1882135FCEF02A709E4596C58D47B0A18AFD6C5ACE1C8074D
  CEAE1693628623A98122D711DEF1D0BEC0E8FFD9D7BA3E3A0D9BF2E38FF240D255408
  2D47E4D5120693CDF62D4C0A55BE170183FC6B363471FB04431BB0D4C00FD4A5B9D70
  F26CDE6842A1895C6E166289FFA2BDC81DF4FC32DC1C4E95C5AE9064E841C7C8F5BDB
  50281C100DE58C728695043A22FB9893CD659FDE3DFD9919BA70A758E2432E6043E35
  49E7EF335D39D8A7DEF0FA9485B616C71758226E4003F6760E1A7975222E79C28BAD0
  D550D5750D0CE2B07ED90672BE130AA161D527F1012CED2013F7556E1B03BA0335501
  3EDA0B3AE086D0A7825CBEB229C61999446042CC732F59DCB5E2502DF439AED0E77C4
  218994FE78FAC6BD5E72AEFFECB29C7854D8CA0D39D7E68D0E78806413D0033E6AD20
  CFD36819EFFD53B7720BD3E938A1DEC9ADB4CF6CADD2BF7F0281C100D17CB4ED5777A
  B4A5A609EC731643D6E981B8207BDB83803F1E1F6A6B51A3B79F0A25C77275C9840B7
  4D91487E3FE91117CD0D9D68B13248A0656BFF616A22C57B18EBBE9F4AFE7DB1E5B38
  07B23FBCDCC8215B196EBBED746109EDABF2F0359C82198D2C92145DE0598A2056333
  52DBB59DBFF059E7C7754B99F9F0792FAB1519D3718D353498A460F468099E20075CF
  08211CD7668DBA1A77D7BDACFC91EC380E28B4851F13F1BD826FABBED060CFE1291D1
  7C1861EF137C85F26EEB79AE570281C100C56F2B9974BA72F40750C6CE20C054340E4
  791861773B023017DB8C5B7BF75DADF8A4A93DD106364B3FD4226085FCD18D3A9F66A
  0E6591EC6C415892D047B1E37E5D31B580EB88C6A909881A34DA876DE0A934E1E311F
  058860725587A9B14B7121DBF3762426A8B88EAAA73958B3784E485429576AC9A0305
  DED39F2650701DD742A5F9875AE1A0F154FB3CED9C48E2D5ACF8162736F53F9467940
  7F566DAD0EC4CEDAFCA6661012BC9DB3C7CE0038077628D4F209C8BC9A5D752007CF1
  105D0281C100C174F2F8C3EFC585B294CBCC943647ED1C173B2BBEEEA2FC31A2454F8
  AABA105694DE72A3A756E3D458A2282D9E4576DEB96F7DDC7D2EBE6DA090F85160717
  F95B46965EC1685640E9CA80CC43EBE51C16A2833A2F6FA21BD79E7DB4F11D8F70983
  B3E905A219A0E0109058708275B7B7EEB2157EB0EFAC9BD7982B1AA9874DBD5AFC88B
  68F91B85A1EBD3301E90E17BD8B7A58D22AE8F356821A0016026117CE6474FED078F4
  C828048EF002151972A03281A570985576D9D6F6D85357C779D0281C01065CEABF166
  FC360FB79BA436F2F6674BD641C0B502B1B071CD8D92BE582EE67FEB632306A2B94F4
  FC31F2D29CC57C9C422DA1A567C413100921E6B12C9D61E307F1364A021BCF323F6E5
  0833D565FA1E886FC05370F2AAFC61256B98CA6D68B7F89C5FE90C026B53CC6E53826
  9FE3350723F6205D9B1B8A6E5BFBEADD7B543FD7F0269E9CCFD00FE888D7012F53828
  E2DA931CBB692CAB71F5E14513451614A108F940DABFCD9BEAC4557EE503BD5196A21
  522C61508521D7DB77A384BA696
"""
const RSA_PublicKey = """
  080012A603308201A2300D06092A864886F70D01010105000382018F003082018A028
  2018100B5F2CABD05BE70474B262A2715B8C4FE74C6F628757FADB3F4815881CD9F8D
  3D2583757DF178B9BDCB207EB183A260934E6580C93B75789ACADAC13C9DD5A21A6BE
  DC4845A76D32F61F37C69B2C0E9D1161459FB1C93CE13E3EA0436B82086DF4EC95860
  D910D32B134610C20E84834A4B9A40C5B4D6FB0732FF5332D8050221DA5101639044B
  6E2B18659E242FEEE58F4FF90BC9BEFF740E22C1A502774E4A0B103F750B829D6B103
  4908DB8338374EE2EF972A0E760DA9CC42F7D160CB33C4918308389CD7EF98D58378B
  B8CF8F8314131C6654903C704EE6BC069B223A39DE1CF1D5B0E34CE02522CFADF24AA
  F526445F7673CDE19F62C6D70266D1F7D03F98F9BD69C1BC78662BB9F52D90C2D1841
  680A9E6528E52BF2F83B84EC73D819240029A677F5AD8EF963843D36DB556B214E09A
  72B589FA139AFAED0EE5409AFFCAAEFC06329E2945A727E1AED64C1935F17F6F1E8FD
  D1B4AE69CACC3DAD8153059B5775A0A3B0EF38E3A18CFE3DB4338F53F03B6CA30E729
  A5EC510C68CE66290203010001
"""

const
  RSATestMessage = "RSA " & (
    when supported(PKScheme.RSA): "(enabled)" else: "(disabled)") & " test"
  EcdsaTestMessage = "ECDSA " & (
    when supported(PKScheme.ECDSA): "(enabled)" else: "(disabled)") & " test"
  EdTestMessage = "ED25519 " & (
    when supported(PKScheme.Ed25519): "(enabled)" else: "(disabled)") & " test"
  SecpTestMessage = "SECP256k1 " & (
    when supported(PKScheme.Secp256k1): "(enabled)" else: "(disabled)") & " test"

suite "Public key infrastructure filtering test suite":
  test RSATestMessage:
    when not(supported(PKScheme.RSA)):
      let sk2048 = PrivateKey.random(PKScheme.RSA, rng[], 2048)
      let sk3072 = PrivateKey.random(PKScheme.RSA, rng[], 3072)
      let sk4096 = PrivateKey.random(PKScheme.RSA, rng[], 4096)
      let kp2048 = KeyPair.random(PKScheme.RSA, rng[], 2048)
      let kp3072 = KeyPair.random(PKScheme.RSA, rng[], 3072)
      let kp4096 = KeyPair.random(PKScheme.RSA, rng[], 4096)
      let sk = PrivateKey.init(fromHex(stripSpaces(RSA_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(RSA_PublicKey)))
      check:
        sk2048.isErr() == true
        sk3072.isErr() == true
        sk4096.isErr() == true
        kp2048.isErr() == true
        kp3072.isErr() == true
        kp4096.isErr() == true
        sk2048.error == CryptoError.SchemeError
        sk3072.error == CryptoError.SchemeError
        sk4096.error == CryptoError.SchemeError
        kp2048.error == CryptoError.SchemeError
        kp3072.error == CryptoError.SchemeError
        kp4096.error == CryptoError.SchemeError
        sk.isErr() == true
        pk.isErr() == true
        sk.error == CryptoError.KeyError
        pk.error == CryptoError.KeyError
    else:
      let sk2048 = PrivateKey.random(PKScheme.RSA, rng[], 2048)
      let kp2048 = KeyPair.random(PKScheme.RSA, rng[], 2048)
      let sk = PrivateKey.init(fromHex(stripSpaces(RSA_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(RSA_PublicKey)))
      check:
        sk2048.isOk() == true
        kp2048.isOk() == true
        sk.isOk() == true
        pk.isOk() == true

  test EcdsaTestMessage:
    when not(supported(PKScheme.ECDSA)):
      let rsk = PrivateKey.random(PKScheme.ECDSA, rng[])
      let rkp = KeyPair.random(PKScheme.ECDSA, rng[])
      let sk = PrivateKey.init(fromHex(stripSpaces(ECDSA_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(ECDSA_PublicKey)))
      check:
        rsk.isErr() == true
        rkp.isErr() == true
        rsk.error == CryptoError.SchemeError
        rkp.error == CryptoError.SchemeError
        sk.isErr() == true
        pk.isErr() == true
        sk.error == CryptoError.KeyError
        pk.error == CryptoError.KeyError
    else:
      let rsk = PrivateKey.random(PKScheme.ECDSA, rng[])
      let rkp = KeyPair.random(PKScheme.ECDSA, rng[])
      let sk = PrivateKey.init(fromHex(stripSpaces(ECDSA_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(ECDSA_PublicKey)))
      check:
        rsk.isOk() == true
        rkp.isOk() == true
        sk.isOk() == true
        pk.isOk() == true

  test EdTestMessage:
    when not(supported(PKScheme.Ed25519)):
      let rsk = PrivateKey.random(PKScheme.Ed25519, rng[])
      let rkp = KeyPair.random(PKScheme.Ed25519, rng[])
      let sk = PrivateKey.init(fromHex(stripSpaces(ED25519_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(ED25519_PublicKey)))
      check:
        rsk.isErr() == true
        rkp.isErr() == true
        rsk.error == CryptoError.SchemeError
        rkp.error == CryptoError.SchemeError
        sk.isErr() == true
        pk.isErr() == true
        sk.error == CryptoError.KeyError
        pk.error == CryptoError.KeyError
    else:
      let rsk = PrivateKey.random(PKScheme.Ed25519, rng[])
      let rkp = KeyPair.random(PKScheme.Ed25519, rng[])
      let sk = PrivateKey.init(fromHex(stripSpaces(ED25519_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(ED25519_PublicKey)))
      check:
        rsk.isOk() == true
        rkp.isOk() == true
        sk.isOk() == true
        pk.isOk() == true

  test SecpTestMessage:
    when not(supported(PKScheme.Secp256k1)):
      let rsk = PrivateKey.random(PKScheme.Secp256k1, rng[])
      let rkp = KeyPair.random(PKScheme.Secp256k1, rng[])
      let sk = PrivateKey.init(fromHex(stripSpaces(SECP256k1_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(SECP256k1_PublicKey)))
      check:
        rsk.isErr() == true
        rkp.isErr() == true
        rsk.error == CryptoError.SchemeError
        rkp.error == CryptoError.SchemeError
        sk.isErr() == true
        pk.isErr() == true
        sk.error == CryptoError.KeyError
        pk.error == CryptoError.KeyError
    else:
      let rsk = PrivateKey.random(PKScheme.Secp256k1, rng[])
      let rkp = KeyPair.random(PKScheme.Secp256k1, rng[])
      let sk = PrivateKey.init(fromHex(stripSpaces(SECP256k1_PrivateKey)))
      let pk = PublicKey.init(fromHex(stripSpaces(SECP256k1_PublicKey)))
      check:
        rsk.isOk() == true
        rkp.isOk() == true
        sk.isOk() == true
        pk.isOk() == true
