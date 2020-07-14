## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Test vectors was made using Go implementation
## https://github.com/libp2p/go-libp2p-peer
import unittest
import nimcrypto/utils, stew/base58
import ../libp2p/crypto/crypto, ../libp2p/peerid

when defined(nimHasUsed): {.used.}

const
  # Test vectors are generated using
  # https://github.com/libp2p/go-libp2p-crypto/blob/master/key.go
  # https://github.com/libp2p/go-libp2p-peer/blob/master/peer.go
  PrivateKeys = [
    # RSA2048 keys
    """080012A709308204A30201000282010100C277609AE7F5A06157D57A6EAACFA2
       1CC01049AF18B9DE167B8B3B933487E9403E915FF3E7896932F4DD66A8B24061
       CC88F8650ED50E3C28026A83A018D994912491580B8FD70313EAB2D03AB582EA
       3B3DEB60133743CA0F15D9F844C1333D64DADD961CFF9E780A6D7F2245A838A0
       FF991955E2958D9B6781D6FD15E3C350D702377EB01823E64927A7CF7098801C
       ACF60F5DDEDB64FBA27143F54878668657945D878981839EDE691393388F75E0
       F5948FE2EC86CAF2FD8882A57566E004A647721F47F2A82FBFBCD9F481D8DC74
       0ED8A2FD9164367958FC55C4ABEC99D4ADCD8D841C616285D3076DE688045359
       3E3E2B9811100A4B8E2C7E6DC5D5B3C93702030100010282010100913BB8B158
       0550A7028313B1ECEDAEC3CC091E0E9FE7C85E801C06FD346140A953511D193A
       559C748AFD82FB004D26FD2B5A5F9709355D66000FEE87B5A761D6583A184862
       3F9133E1B773DE34CB3605D283A43815B11209DC26F2CCDE81571BA87D8EEBCF
       58598C682467C3201452E1314503A87A4ACCC22BED150CB112A09EF5E9168FAD
       E3AB135DD41B455B2754251E557D6AEC20B7EC9B38B512F1A93F40CD31D59071
       67555D17A72A00E4BED5857D3CF9965016018F4DD0567A4C9440D8AB1C7A82CA
       E3C2A34EF8CCDB81E3D070ACE7681CBDF5A438E15F6F2821D51F654467CBD509
       576D5EBA6F3FF7B15F38FA92AF7F9CA92C0A41E10F038647920A4102818100E0
       17CB68FAD59E92C5CA8F65C3C95900789D092755343A667ACA8C5BAC626EE30F
       789155F0E07D7D00B8132C502CF8D02CF7D7699C174193BCC5B821F3792AF060
       E838DB757929686AFF95BF9966A7B11951E16FEC07B09C16C2C27A3B1690D02E
       4D24E89C0BEE63A786CA70AA9DD7BF78E59CF364A194A858949ABA32CB296102
       818100DE27B098887C0916D1F6CF7782A6B5F7C8A699665B49A5557317582329
       A61E411E36BEB2050390531E43466356D957825ECF49F889F2F4C1FCFD2B8855
       ACBB2663DF7F362F6FCCCE883B850F215A3E37D752E20549B429A0A90149B761
       A8D566013893D0B7A5E14D78F2237205ADB099D43A01CF573FB61E6DD9431407
       D501970281800BC7946CB74AC56427BB87202D5387372C1FED1C413156A48E6D
       D944F461D43C6152D028F959839F2F8B7D8E85C4676BE20141348EFCF5F88322
       CD94134D5A417A869A7E86C550B4E972F7F733641F0A832F37AF7F73C407E076
       6A6CAC707A3A4744CCDCE15F0B2FF7DD7104CD2330F522B0C7385020E2449B2B
       6C9ABF12C8E10281803ED36EA7D4816F789AAC7803CE5923410DE7BF9E28D6ED
       00FB6970AD910BBFA69ECAD0A73BAFC4531D4DDD4C1EB59C7FEC1C2749388A13
       1A0157FFC5B0A506D0569250419CACBB78F52210013567760D08C211D5790090
       7D350E7E307457F0F1C60AA012F8BCDAB8B42996489ABE82211ED9C0C5486166
       39B8CB26A3358BD1C5028180412A1CE4CE9DDCDFFBB2AC90DD466C21D75F13F1
       415967EADFBD9E87AF3DB520B4D87B1B619DCB26F32B500D439A0A4E7FF44A2B
       6EAFE424672F5A249BEB74D72A4A04A2EE2B5546571A68C79BC290677039E9C4
       84B192DA4B7C7F72C21695403D421238539216861160351B99FC0BBD0F9D1A76
       6A900436BAD373F31AAFBEB7""",
    """080012A709308204A302010002820101009C338EFF095FB3F9989288D3B0D1EF
       4A425E887A109DD9E212311EACB8AA6737B53F352FC4B948E9B5BE9943C98516
       E71A85DD7D4A49325133294CE82D4E262FCA647444907BE36727DE527892DDC0
       BEA272F767EC596429E1DD4545D7910DF82ABA72C71EBD8D4E34C6C0424BD6BD
       66265DAD0D85A8BF912CFECCEB9B63B6C09A6AD026D70FAD445BAEE39ACF6DF1
       AAF81CFF3D6207053DEE94569C24274B9307CEF9770385C1FE65D8B502526903
       D834678F17BABEA1F9850B58C54B72D5E52E13B5C3E796BC3B989CD9FD616598
       4BEA473B3157A1A61C072ECECFB12E09EAB2EDE57A7B5F1BE9D49C8B5242F7DA
       90BBC967BE92C761134E69D2F9AB0451CD02030100010282010030F794CF6CDF
       DCAAD562B294326D4DA7A8F0BBB610797BB17C647BAA47E5DB9FC22903826B18
       6EBC1D6697E3814C40A6C850C8E39B23212C056EE0163505B7C0E9A0DE361459
       522BA77AF1BDACC4E9C49966931AB82439DB4B5C337836A0D9913FCBDD6980C0
       8988C7D0BABACDCD8EE874048FD89A5B115AF0911C2A8C37113608804DCB3D04
       CA34EA7E184A3011C42525D8B2B00B12D45CCD533E32D7014E5119CF51954591
       0B41E6845019104B5D63907616DB0CF0EEB82C449DAB0D1073D118660972D337
       7786A662CE219F5012F4DCB0F0E2257F3558EDF372321F740458B13DF762D8C0
       D51AF28024198EE6E134CE2C9CCEB3940FFF04D8A5A38980D42102818100C170
       DF5FB4F412E18FAEA20C7C8C768B59933B72B12986877763706CFB8DD0062781
       DBD2102CD419DDFF20C39FA3B19AF9A10D7A38F9C1D426666521E4BAC7B7847E
       9838BF9CF28E4B1D12B7FD54166FCA81095E5557486F98641C7BAB6A6EA55C9B
       CE2F4ED6B56BA259F93D4D95B32505CA3D38F7680310D03C05D36F6F9E490281
       8100CEB798EFF7EDC87E46A2FAD6E061DBBB0051366E5FD6234B857B8B0F5501
       BC3708D7A23DB9F029FA4A17DFA9D0E1E271E3AB3065732A6525C4C2A881831C
       2D35E56749AAF26AC51A3EDD6989C7E161B3421AEE565CBFBB9C779BEE4182BA
       6CF8AF844FADF56C9A54C85EB949447A16D3CD0188A81E191BA824E4376286EF
       E7650281810080A59158B41E5264424B30A83F38A729FBB38828B99BD5454868
       107FDA3830EDB6DE8D13C2001E3AE9C1DFC759E6E29A1F843553608AF19626C7
       9860971E84EE0EA6A693AF1330D8E3297DA6714AB7F536E6E415218A7FB8FFCF
       2C862EB504CAE2B117C9AC93EC699DBA5AA0A375788399BB2B46347BAEF64296
       78856A2A004902818009089CF65FAF5483B0328F23B4CA91FFAA13E27D10531B
       57C18D949626F0DC78CB3A212CF1633D7262AA886BB3652BB02E72DCBA923DD8
       0DBE7B8341A5A92590A565CE225A55B0276577E794CDD75B9DA9D5E37482B91E
       49C8305849249D6105BD25DB158F141FEA74972F21B48C6153003280F657DA61
       0B0811B119ED2BAEC102818077F48BB3C3D417DC4A3D1F871FCD21A6434F1F55
       B73DF98524011427524695562A63DAE828427D22897EF60CC5E6A8591E8305AC
       202749D7459EBB85E4D65BC9CC44E251F92BDFEA5279C2F06647A2A29C62E90E
       37C7A3A72EC0FD20D9073D397EA1D6723473368B28ADA577FA8C2E840EB769FE
       CC8B5863789948D6A1550344""",
    """080012A809308204A40201000282010100EF0EBAC68BA931EC25491A9E062F11
       485E4BE8CE5A3C7ACB9B058DB956517B76AC2227AD24CFE3CCB75DD4B3C1059E
       5FF472FD07715E2DACC97D809AC8CA3C37FBFB6352B956C0F6B9B28CB9ED291C
       85FD2814D954DECFB366CC59F3B1C74D477CE9CC2177C9A70041C5C7848627FE
       4599FA1AFEFB7E2064E917C56123C717E8670E35ADBE7E0BF981A7104CCE17B3
       3758D75F09B42FAEEB6A5ED2B458B798DA2F7C5BF020EF83F4F947C583CE5797
       D3E6CCF815040A13CCBA898EB3EDFB57C77A1C6A6D58122BA87BF7C8E581E0A4
       F6E96DD783025C9B7C1DDF8F0ABE286B2CEADB884FE1B3081F9648448D5A9319
       9A355C7FCFEDF72925A6224BA1E64749290203010001028201003E0ECFD3BCEB
       B646FC42E70300CDF5299939117D88154D374FCDF84595AFDF62263B539B7203
       F9B9EA1C149C794E3117EDC870011F9FF83173B8FDCAB0B7373CBD503C2F7C67
       95FE36A4B03D8FE06D44273CE174ADC08DA09FDE0AB7E57DBC85035B5A1F920E
       2A2939E9D2EA873D18980EE9CB5A48052CF9A53D03833D1B710BE64B2D7FEE62
       66BF2C2A002C9589D8B9D7710244078FE2F10D18F45962B86F4FF834B3A5C8D0
       080C9F36CE556E7BB5D9AF79D91263A179457575C84009C5A219D23A99586762
       16319E1D5D85723771625FF80BC7D6A6665515F70EED682BD8209057DF1F6326
       A1734D73370F54A388F08C7379F07929DF1CCEA3D813772F126502818100F939
       9034445E74434F6E7794874866D793AC180E9C2DB1F37327CC9C085789279F23
       AF5BB5323379565AADF865FC2376D8DCEB0C79580525B7FD3CDBE8C8F6CDC295
       D852FF40462B0D7AA05B4265ECDA4C4A2C13364A772AD57524D17F8B38A65784
       03DF83C2702CD98D1A03778181A738FD05FF2D80D3082D99D6253DBB8F970281
       8100F58E689B42904F62BAE4AC2EA87D8EAD61B93CF19622B939FE22F95C1DBA
       8A53BA5555F9A321A6E7A83B3D4F4BDEDB95068A9BD42E7CD61B075FEB5FD26E
       9D79502CA3A9C080EB0C00126B0D5064EBEFFE437036533133259895EB18CD14
       095D7968A63382F0DED2727AD8A495E0C5774E59B1199BFF568A914E616C9957
       053F02818100C73F911D68478775C4CC5147EABC249457187007462F7624673D
       3B64C77A8C49A3FE18951E10EB7C2760C9D35C5DAF50B5E230FCC10A70DB0DF4
       A4B23FB263366F49F32FAFA80831254E9363427B5057DA44366689B21101AAB4
       43E245B0DD72876720DD926E61D6497B787FAB0C5BC6805631742841E4F595D7
       76904181713302818100DC6E154B62CA86E8FB1AB1D244A049872D158B36D76E
       9E5607E3BF7348A09EF2206FE078F34F0F341F99E6249BD817C7C49282E64B40
       F736563D6DDE9BD97E755B5A6724C851322E9895F011889CC00BB57536731DE5
       29A3D340A9459F3B20590FD6B873BF5498C1D3D0A14FC5D77B8BE902ACEF6F51
       1C8FD176CA1021EAB32302818011C9B0591DF6F20172B6DBE725C14CAEB91A6B
       8C112CC765A5CDAC993ADFA031465BEB01C55212D8D30402B2C479D072642C48
       7998D80899881202CDAFA7C3CCD2B87493C4F8A5E40E84A8E63D93B95F370C0C
       15A353C1BF0E625DB36257A2A499AE5611ACED18EBF0AA669D45AA1DC0583268
       C41737A8ECEC1978543EDE3D96""",
    # Ed25519 keys
    """08011240B6F99B4E4422C516F1BD135B4D2B02AE62C48388CE31AFBA16496D2
       42FABE09BF3848ADABAA9F1E1230A3B94EDD3247C2395397EAFB59790B86595
       F94F1CD6B9""",
    """08011240C1F64B208C6D3F52DDDC2CFDB41D5555956C6D6AC6A006C0547C94D
       8AD00A639AF87C6EA4451B2C7ACF7E24AB3B8FDE206A984BB0F1C1338CB17AA
       F65E944007""",
    """080112401C2228F2880999FEC64401DD33A48C9C56FAF47EEB715CEA57F9F3B
       FEAA6E9E132EFF1CABC2A629690CCE7978241315A965F3A1702AC63860BE42D
       72265EF250""",
    # ECDSA keys
    """08031279307702010104203E5B1FE9712E6C314942A750BD67485DE3C1EFE85
       B1BFB520AE8F9AE3DFA4A4CA00A06082A8648CE3D030107A14403420004DE3D
       300FA36AE0E8F5D530899D83ABAB44ABF3161F162A4BC901D8E6ECDA020E8B6
       D5F8DA30525E71D6851510C098E5C47C646A597FB4DCEC034E9F77C409E62""",
    """080312793077020101042027DD515F39628504923D5A8935A95DE4AECE05AF2
       451067A8B584887D67B6799A00A06082A8648CE3D030107A14403420004B544
       92DA731A868A0F249288F43BBAEEC5FB166BB430F4AD256399FBD67FD6255BD
       5ADE57BA29BC6EF680D66A574788A03EC30B9D2F1C27A483E59FA62F6B03C""",
    """0803127930770201010420746C012FB8E6882BC696AFAAFBCC4B16F8674C1B0
       07A7F949EF0D6D485171ACEA00A06082A8648CE3D030107A144034200043E41
       50BEB59FEAAC43389ABC490E11172750A94A01D155FE553DA9F559CE6687CDF
       6160B6C11BDD02F58D5E28A2BB1C59F991CE52A49618185C82E750A044979""",
    # Secp256k1 keys
    "0802122053DADF1D5A164D6B4ACDB15E24AA4C5B1D3461BDBD42ABEDB0A4404D56CED8FB",
    "08021220FD659951E2ED440CC7ECE436357D123D4C8B3CF1056E3F1607FF3641FB578A1B",
    "08021220B333BE3E843339E0E2CE9E083ABC119BE05C7B65B8665ADE19E172D47BF91305"
  ]

  PeerIDs = [
    "QmeuZJbXrszW2jdT7GdduSjQskPU3S7vvGWKtKgDfkDvWs",
    "QmeasUkAi1BhVUmopWzYJ5G1PGys9T5MZ2sPn87XTyaUAM",
    "Qmc3PxhMhQja8N4t7mRDyGm2vHkvcxe5Kabp2iAig1DXHb",
    "12D3KooWSCxTfVvMBJbpF75PQmnFdxdBfC1ZxAGYbFc3U9MjALXz",
    "12D3KooWMdZbdEudjgnCvQLoSoiqhQ4ET2gaA1d4JpC1CBkUnfzn",
    "12D3KooWDFCm93uCnm8tVdk3DYxNeMFxMGBaywVSt8a8ULtdLoeX",
    "QmVMT29id3TUASyfZZ6k9hmNyc2nYabCo4uMSpDw4zrgDk",
    "QmXz4wPSQqYF33qB7JRdSExETu56HgWRpE9bsf75HgeXL5",
    "Qmcfz2MaPjw44RfVpHKFgXwhW3uFBRBxByVEkgPhefKCJW",
    "16Uiu2HAmLhLvBoYaoZfaMUKuibM6ac163GwKY74c5kiSLg5KvLpY",
    "16Uiu2HAmRRrT319h5upVoC3E8vs1Qej4UF3vPPnLgrhbpHhUb2Av",
    "16Uiu2HAmDrDaty3uYPgqSr1h5Cup32S2UdYo46rhqZfXPjJMABZL"
  ]

suite "Peer testing suite":
  test "Go PeerID test vectors":
    for i in 0..<len(PrivateKeys):
      var seckey = PrivateKey.init(stripSpaces(PrivateKeys[i])).get()
      var pubkey = seckey.getKey().get()
      var p1 = PeerID.init(seckey).get()
      var p2 = PeerID.init(pubkey).get()
      var p3 = PeerID.init(PeerIDs[i]).get()
      var b1 = Base58.decode(PeerIDs[i])
      var p4 = PeerID.init(b1).get()
      var buf1 = newSeq[byte](len(p1))
      var buf2 = newSeq[byte](len(p2))
      var buf3 = newSeq[byte](len(p3))
      var buf4 = newSeq[byte](len(p4))
      check:
        p1 == p3
        p2 == p3
        p4 == p3
        p1 == p2
        p1 == p4
        p2 == p4
        p1.pretty() == PeerIDs[i]
        p2.pretty() == PeerIDs[i]
        p3.pretty() == PeerIDs[i]
        p4.pretty() == PeerIDs[i]
        p1.match(seckey) == true
        p1.match(pubkey) == true
        p1.getBytes() == p2.getBytes()
        p1.getBytes() == p3.getBytes()
        p1.getBytes() == p4.getBytes()
        p1.toBytes(buf1) == len(p1)
        p1.toBytes(buf2) == len(p2)
        p1.toBytes(buf3) == len(p3)
        p1.toBytes(buf4) == len(p4)
        p1.validate() == true
        p2.validate() == true
        p3.validate() == true
        p4.validate() == true
        $p1 == $p2
        $p1 == $p3
        $p1 == $p4
      if i in {3, 4, 5}:
        var ekey1, ekey2, ekey3, ekey4: PublicKey
        check:
          p1.hasPublicKey() == true
          p2.hasPublicKey() == true
          p3.hasPublicKey() == true
          p4.hasPublicKey() == true
          p1.extractPublicKey(ekey1) == true
          p2.extractPublicKey(ekey2) == true
          p3.extractPublicKey(ekey3) == true
          p4.extractPublicKey(ekey4) == true
          ekey1 == pubkey
          ekey2 == pubkey
          ekey3 == pubkey
          ekey4 == pubkey
