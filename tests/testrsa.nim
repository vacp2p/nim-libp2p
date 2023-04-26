{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest2
import nimcrypto/utils
import ../libp2p/crypto/[crypto, rsa]

const
  NotAllowedPrivateKeys = [
    """3082013902010002410093405660EDBF5DADAF93DD91E1B38F1EF086A3A0C6EA
       38011E58E08D27B163A9506AB837F4AF5CA23338AB3BFBC0AC7A0FAF6B9EE3B1
       27BD66083C7B272C1D370203010001024017EE5DDB74E823F6655197B1ECC77C
       DC1F651254BFDF32E8E3A0B825D8AC98B09D979753AC4F496AC5E66B5CFD740E
       86532AA1BB38C0E217C1D3736D519E4EC1022100C3FEB2BEA19C735EE3203F5A
       F05E097491FB323217AA1A8494E2E623D9BDA497022100C0554F5A22AAF0E79C
       4E84BEEB336E975E6315664BB97E51120F6936DA8D40610220119A4877729058
       944715D85AD487BD95A89EC4ED56CEC23EF21846CF257930D502202372D5C848
       21777B48BCD40C982F0790108E7490411EB4205F12C6129D1F71A1022030BC71
       BF63EA847A3A682242AC73F3F3B4A232FA0BFC2D2892B7D8AA24958C4C""",
    """3082025D02010002818100BDB0E9A7AF9865E318C8890A883D185F6D9F88868A
       5F586244CA6A07F298349EE52E38EA322D7E453AD2AA8B5019C25C50AEAAA59A
       FA57173F2B3B44501EF45BCC6C1F75BEBAC5C11D7861A8A9DAED68964DEFA6AB
       D0D9FE232E6BA9E97572B6F68C57030CCBAE19E972D16338201B7C11E00364FE
       7D613CB3367BB6CF2C3BE502030100010281807E679DCC785EFDC64F85928CCA
       2CAC492B2BDC368B8EEDBECE48744FC78155CF6CB95883F7DC0900E929E92BDC
       BCCD9FE6C3FE434CFAF57E304206C486FF99A54CCBAA8396B6F6A85F72C9976F
       1B2F376D4518F90481EEA12D4FFD663505F2170473FAE9D593D2A5E8D754CFFE
       06420B464D2EA0DE17D99AB453148D85264721024100E2B5B2266846CC59CF7C
       238DBE0A2B0EAA2AB23E1EE1298E695B1A2A8C0D9B33ABB912C9558BE8CCEC5B
       25F7CFB77E8CD59E63469C089155DC29F2B1C1F5FA0F024100D632D7F41EA20A
       622843605354F05451F889CF4354A51B92C7BF1737B1EEDB9C4BBEDEF1EAA8E8
       763C5EBAB618527A692912D79B610B94D88C97B6ED2C0BEECB02403A48FE4933
       8BE823BADD2E82D575E5C5FA67C9B580D8E087357CEF883AC390C04308ECD488
       42D512423DD8D0123E19B1F985A3FE564539A03A5F2A7F1ADFB36F024100D4F8
       3E818987A17D50FD14A4263AC20BB26B0AF9AE0A6FACF40F8A3D251C119C882F
       6229F42036E98042CBAFCBE50DB2CB54E1ACAAC3C21DC144036C3334361B0241
       00C2200411163DFAD0D56501AB1076A2CD7CC2FDB066CEAACD8212EC1F292C22
       F1840B8C1E23D941436F2EB38873FB76DC649D4DB85FF026D1D5DF405481A2F7
       F5""",
  ]

  NotAllowedPublicKeys = [
    """305C300D06092A864886F70D0101010500034B00304802410093405660EDBF5D
       ADAF93DD91E1B38F1EF086A3A0C6EA38011E58E08D27B163A9506AB837F4AF5C
       A23338AB3BFBC0AC7A0FAF6B9EE3B127BD66083C7B272C1D370203010001""",
    """30819F300D06092A864886F70D010101050003818D0030818902818100BDB0E9
       A7AF9865E318C8890A883D185F6D9F88868A5F586244CA6A07F298349EE52E38
       EA322D7E453AD2AA8B5019C25C50AEAAA59AFA57173F2B3B44501EF45BCC6C1F
       75BEBAC5C11D7861A8A9DAED68964DEFA6ABD0D9FE232E6BA9E97572B6F68C57
       030CCBAE19E972D16338201B7C11E00364FE7D613CB3367BB6CF2C3BE5020301
       0001""",
  ]

  PrivateKeys = [
    """308204A40201000282010100B7362C6653ED53C35C3AE663DA496C9B834FF34D
       72DA98FA6DBF4AABA39FCA0901F58A1B1D205076D20010151DBCA8FC2693E14D
       3502320D61E796E9C102C4EBB8F50B90616DE7FB8EA0A4BFC89BE542CC86DB7F
       179B153BC325048BD43A745A203F86B48D54589D4AFBEE128DCAD9C481C157F0
       AECB1EF4720E0E8535C96C318F3B53FEEFDD13774981BDDF6CB60331B2A954E2
       D60DE05961114A8B05EDF13DD116AE47E930CAC1A56FAFFE5438AB5DB0A88A35
       63BCB9B4315121FC4685317847CA4806722BC74ED9954F409D42CAA3BE028E25
       1FA0218414F2ED4469ED78C601C71EF7C68D06BBA24DCDFDC8DCCB1F93A72896
       756B9CCA840E4188D8D02F89020301000102820100532B9596526D3F84453F3B
       CD828FA86D247C4BF011BEA889AEFE92F03E1450CC2C06824E72B773AFACFF78
       4D8DB552653D420E9A55010D25C417350C22A1963188423DA0AA8A1130C27BAC
       AE9F6C1DF46812A45C1AA43D4C66F74C0C0A290B1ECADAEBD4D4FFC0468F7EB4
       81D9BA87874C7C2FE6C402D3A7968B490E31EFA15C4D75FA6DBB49FDFBE5FA79
       F3A2BA7B519F6736E0786A78AB09DAF4F2D78C82DCD2342966D5D5C64E7F728C
       B26D01847B30164CA037C44FD9A410F327C20273C26D708FE64F9ED739A43D1F
       97468D9BB7F789D79329CAE445CEA3CE2B66DD1552E29DEDBFFB2C7BC5B7C7CC
       513C410119E25C00D51849D1D85331C35A2527A54D02818100D1CFF7A51E0F10
       39FF367CB1D13EEAE02CB54A7E155007BA981F25EEA673FD593642F63A49C934
       DC0B907AAB94FEB1A0ADCCE528A6C047137CF2C9A0479C53F4348769F279E5FA
       670C31D0CF922BFE3056B55049149756C3F4AEA085BB5CCD626265BCC9604939
       DCF8F0CF24E2088B021FE7803121C1B9377AC2C4B2296252FF02818100DF8B1C
       FCEA9D5781B72CDF2FAF0C728103E93B09F861632B6AA1144E7A7BD0FF737812
       B8B57CDF5A7276340860EFA2881CE44B834A879DA0489D5F80FA40ADC4E90BDF
       20FE3101099B3BCB053BAE5C4403D2E5F6423521B8A86A1E8B4D79384D04B629
       B9EAE7324669B59FA4DD2359D3B6CC40E5A198FCF2D2F6B57C07A36577028180
       3EAB06861C2755AA6D0F62495E7D937C27FE72649C8B0DF3EEF206CB748E5A92
       E60134388EC779716C46D84D1DB0C16F83DA1A6C7CFA1B80B7A67110DDB2D4E4
       B137ED2E4EB8A1855C00192596BC6B2D17090B14F900871AFA9F9A34B794ED87
       C06A30EC594525F259ACDBC2617D39C005B588F5A3E690230118E1D57144FC13
       02818100BC1D2701B6B53D644D2F1789DAF6D08CBD2BD1A0EC4197E07B549DF0
       04A69913BEA9B6A77522661A88E3EB9979696F0EB7B16DD2482FA377B463AA70
       B1272893E1C139BD5BEB05027E7D6CB534A9DFBEE4B0DF0FC25B4FCB42FE3A41
       E3AA34B4AB5857F8BA32605E5CAA9873761C3F8527F8EE4BCF171D15826E55FE
       CFB6B2B5028181009234B4E0D11E2B61E46FDBDD5C577BA1DDB4EC9AD70D2EC3
       69BE24654A493672A5686D76AD357ED6203FC1896BA57100CCEB7491D1A5A728
       8A97B09FF1DC131E7136B557002205E2ADE5DB114499F15AA1E3C6C7E6FE6381
       04B6A67697C60C4113F613130403C554688C7046D6AC5F5364A658917E23D40F
       1FDDD3DE4C9F51A9""",
    """308206E402010002820181009E4E6CCBE33B69A9FB6A3CAEADDC47E26AE15E1F
       F8C56B3126C4C66E549F86F0002A1CC3D0169F034825A3683AA0A579D844B415
       698F6F2AA5907246D911CFCD69A5151A78BA5AD803A8FAF0184DAD4BF471469D
       B91BE951FD12EE5C8047B536984873A4F79BC054BF0E0A4730A1B20C3CF92440
       B1ECC5FA608213AD823C10D9994B3F532FE5FDEF25D6DAE7CDAF1EE7238E70F1
       59BA05684261A49050B8E3F37141D13A328A4418168629A5CE8845FBDB70EAF8
       988617D5200F1D3695E07CF72978B220AF30E9832BBCFC02273716D2851D43A0
       154E16DED7B4975C1881411B63ACEEC3EA7E438DB441128BEB77BC7D452C931D
       C8C03E8A882F85BF6E211EB79DC649A2CEF2F1A197EA69C022C6929AA79D9BAB
       6BF56DC21F7E3A70192F2523F8393AC95ADD0C07889F31C4BB2F936C35D2C25F
       9BDB1DCF131FCC87038C5F53898616956CC92FF904ED9DE01202630100E99D76
       31556C3A335B4E44D74C2145F7769E071576CBBFB120850D85C524F0E613705E
       0EF3F8D2386F4EBF47520FB50203010001028201800C32CADB63251EDD444C49
       64C46CE6F5217B403F8271E3F2A3A4220E3A631888C1DA7CE0F1D5EC66DA565C
       2319F16B0EDA8560C30DA149D5A5705DFDEB981DC51C50E63166002623E31450
       51D3ED985EF3F50E95F4BF9BD8FF8147F0C4C9C1C2F535100434384237C58915
       6DAAE7AACA9AA03014F420E498887B3D7CEF3E25A63ED3B78B7773677FD81098
       49A865C821D371946E64959AF90FB46A73DC6482DC2D6BFEED571BA4679EC4B3
       CCDCFF4F353B11966995872FAAF28F7796CF31BF2F457270466CF15971A2F0F1
       89EA7F9B68EA76290F06FF4FCE9D3A4526D9CB111B5B606CD6AB143B48D5444E
       1CA10F24AE42C243C9CDE87CFEF846D229D76707EB3ADA819C073FD4D601CB2D
       4FF7E58F61363B76826394327D1460A334C5C09BA5CEB51ED865ECC5D0BE75E7
       19939A4C029F0AA49B5E958EC8303FF431D251CA7B4EA13158C3C61758675390
       A97D2BFE31CC592E249E78B55D434D837DD0F471C5782244C8ACCC2FDFEFDAB7
       0FA53B8DC8C60933B94284853199C7EB6F9B7070F90281C100C9707D75B3C445
       93C6295D6FF65FB41F38C74A8B358A3D6AF188B99971ABCA0B3374FFC15DC154
       3DB4B4B502331E5FB075987C68FC42844855D45303DD3B78FA0581631149E31B
       7739E13C7CE2D2727AC75ECECAFAD3C2DF63A147134A9476F8DFAF72C74DB184
       875434F94BD8C617B60B4CDE3C5EBEA372CFAB5FBBC56ADFAC2A5C25CDB157C8
       56579AEB36338791AEFCC46B62481F3EABC753AD1ACDCAF2C1856B0E5F061941
       4C1B5B133E25B70CD92AE6CDEC776A8D064BECBF11DBE3794F0281C100C92F26
       EFDCEB269267FB024A9C3BC33187CB80FAEA989E3F3A2CF657226D7FA8D9F32E
       D3EA93730F7D1BA7CE807F3155E9CF931A812579CDF194C3608B12E66967B7F3
       50E4AD150878F1CD4B18BDB7C250F3D69E078F0F4B6BFC32DC3369D7B7318896
       5A6BCE2A73EC4BEDACF6165DC191C57A642AB69DF5B5B5B1F35D9488035FBF2E
       A0BE3D0868A66E2C93E06EAEF6080CBC94D7CEABC895751618AD6ECB43C4146F
       C5FD7A4CE761BA24F0EB4C7F159C74A18201174661037294F9364D9DBB0281C1
       009C2D2DE822AF0A6EAED5854EF80A6D4143A927BF548C505FE8D1E36BF73884
       963897FE6E71FD210E125B84772720E6798E42E23A17528EF2F23083085CEEEE
       35922D259CD2D754851487EF78B7F707B0EF802EFE2A8821EF46745501BCF1EC
       67BA2D71E4D9F4C6D6914FDCF49425C95E67D679FAFE4DF9B55B12F84F419941
       BF5EBC40C7003719E8EF54FA05F4DFA7F0AEA2AECAED35E446146D68A97E6259
       E1F649F143751C01873B325A71F595BD4D6638B9F11B08AE3BF283A403F9A29C
       7B0281C077FAB2D1E1822B62ACB839499D9AD671B77659D94A06F278EA8CDDEC
       610FC44E428C90A4B9046E5E125267E4F324E79B40F115DD7C9F88E094EE0F06
       886A2117434FA4BFDD608B669E1A36404EE4F5ADE0F14A50BC5948D9C5F085B4
       64C4FE6CB611AAF909C9CDEF8C404BE2167088416459CCFFE7A938D2CC272B94
       E37E2D0F360EA21422DFEB1FDE015E7C6220201F81F576919D9217486C39838F
       FBFE53227AD16547423FA99563E6CB19127A705FC70A97371CC770A57294E6DB
       28D368F90281C1009D7403C764BBF9CC1A23F600E542B3069F1FC6C8B44D1C21
       BF2260E65EE86E4116E2CDB721257BB2D27BA8648DC47A3F583D2234263B24EE
       49B5549C8732D14493F72BB4A1290D70A181086A2ADFCA250FDAE11245353032
       5A6E065A8C96E59E11BCADB3C4810AC2B1899AB986F62282B430EB317B771E6D
       B7D2FC2F3F1A8C73CEE0095C67D102263143A518B6622EC47A39B52E276A82D1
       CFBFCF6011D9ED12206458512E807B310D9643FAB61DE3F517441116D7270E9E
       B626451B5007DBCC""",
    """30820928020100028202010099EBDD4A8DBFD112966F0242CD0D0DFEE9A48572
       D49ED4F1E8BD52A08924691A6CE53A47140EC84D046DB142E0607733204FD461
       D8CB58BDBF05E51FFB77854660ED814861429AE54BD682A06F0B3C51FBD7A27D
       5117862D9EDF6B6A51B4E91F9A973EC3F8EF223EE656B4DA0B1CD41B323EE1ED
       4BCF88611C7BB11EEC1C7ED7D058B1E0F589D3682B25534CDD56F125D0298DD5
       45D26BEB6E1DE1A5411CFE2520B066113AE24198BA24BC47D33B44552A1305E2
       1FD6E1E1699DA1DB04975D35B27011AE9E613B7D4BD7F8144C00E11CC6704CE6
       5DE9761B4ACE8D1F6516BE3B83A8DA3FAC94391DD2FD503342C0D92400461520
       0F40B2BD0430A4472C0BB43F1629E851B5F87ACA7AEF56C06FBF5E2E481DC07C
       E1A8A06F20ABC88203E2C588AACD1AC9CC8D42C52A37DD6CEC2E4916B3A4DD1C
       F24B82BC6E02A0B87B6436AECA94E271D571A2FC7AEB494F180EAED8DF63B9F9
       06E725447C1E3AC5CE54D996B7AB6E41E2CCA301D901716C886798077C61801B
       F770A2A20F9E08BE57F9B02C56379D4B8D32DF4D07B3E70F781CAA4147B6F6A0
       1BEC7AD99B07FC5DC8927A4DF9B17DFED8B01CCE57F78DD3EB1A408C900024CD
       B1C5C909F55DC9D8C9E1F38DD52A3DB9287276D556FC1E5CADB7F727A0C74108
       CF0F8D88948331E024FA6EBBB064302E58B4FD3EAD0135CA0BAE5BEB2DC6DD5C
       AC02EF7A59743F5415109D750203010001028202003A518A9BD7CF48A8F14488
       27C5475FF9288F445CB8C0A15032EDA0A3E0B261FC382C36037E4F07875ED92C
       E378DE33EBB41F6B09D3B9601B2C885042E8E56522C050DCBE0ED3CC9A7A3C81
       6BC6070CC8C751F167E7D4B0EB1219F6B9E6D153CEBCA4F78C0B0298081AFFD9
       30102BD115A8D8F8830F494793FBD5C5CB408C9F66A7B3235A67CDDBC2C92E30
       3C9C5477B3EB06038E3E11370091CD5294697251BCC180F47B2CC3533549B9E7
       7893490E5FF23C18EB8F42BC7CCAA6860FD4D280E77A7F49C3CE906A98D3A6B5
       8103370613FFFFC6B335FBE1DAFF61F9485EE5DA17F48F8279C3AAB9655A6ECD
       F74E20816549914429CC7DA7FB43DE26302D39160686AAFCA829C56FFBDEEC24
       EE70F9AD7F2363EB69FAE1436402BF55EC20A0C40CF0D7373FF55166644620B4
       87006235789763832E7AC18852647449BA99955F3F35809827EF40FBAC271666
       014AC48AB9FC70CC79A124A248ABDC791D87B957DC227223BA00269DC3250C71
       C42029659BD1DFF8F2709272061ED18C7BF2C627A245F33E5DEDC9F00270F910
       C778577AD94988DCD7795C2F507D04365E520500C05044FFC19A809B7A11B87E
       0AF4776C210E28278AC4C7F656B90D8DCEA7D5E39E8DBCF76C505E64EF757B37
       8984070CB9F777A780D8595B17943C1BB5D6B26253F8BE95CFA79F1B736ACAA7
       AC6B900D89991B31271AB1251FD3F26DE1A8BD4AC10282010100C23FB658997C
       C6E33A0C61BCA39FA63FB5188ED619F3B5C93602C218338370BA0F199077098F
       E134E9625FF54E4098E8ECEEDEE2795A829E0DCF5EA79EC2F959F2D811E98A8C
       5240DF704C4E1EC6FCBE842B9A6D835234DCE9E69F7D24CD82A77924DC9EB9C4
       9F8157BDC902A1E643C5C640077D3FF4FB2CA463115154BE346AC35932F1A403
       3E4439993800D17F5527340368C4CEA4519CCBEFA27D82035AD62899D52A1FC1
       F77B67A538A979A6DBC304C16AD49BD8CEEBB9AE52BC05A715C7772934346859
       4FB7BCD379ACF76EBC7DBE7A70EFCEC61E8B5033E423426FBF23F688CB5405E9
       4AAB1EB0120E08755F3F681CC2964D661A4DE67B177885E779D10282010100CA
       DA3B820CEE14BD3624C936957892A76AFF59B203BF734797824E24B674758B19
       F90C1EDB590ED23D810EA9649D5DEB79DC83B7E93EA99F0077BBB0C30FE53017
       5C57099A528EC12AAFCB28DD4291135811122B3C56CEF79351A0E46C37DDCFB4
       280C3FC40A9F782FDCF9A892E3606E2184C6A659D2159F49C4BB589B69A561DC
       E0741793A33930F626F474E16949817FF64103D90B2977BC5AED5727172EABEB
       F771020FCED09A2D3C5D7B29AE5BE7DC9E05A59D730B04D8BD8CBD6D18DC394E
       69121540D15A5B380B74D4DF67D4B358A620456024F16859AA14C1B74A4FDA6B
       2D91197C88232C67AA485FD224C222DA4E80132B07D966A040339977BA2E6502
       82010014CACB12EAC2FF6AFD20AC298BFE1FC67BF4F7FD14E410564C50B943EB
       E7AADE4F9575F037F6CDAD6339E3799779B4A46210238D6C5DF2D3463927319B
       FDD4C0FB0C83C652CD3854B75606E4E9C874EF53A8732C3BBD45E94BA422F83B
       434033FAF4A624DB4F9F9F31AC1FE3073F658BBAEFC99D6F862288A1C3F4EB96
       BD9150C83E3904C280925EAD27A865F606C22FA312A65942A1361729812A0C73
       2936C4EBADA3B29199AA8AEC0A3469779B13B4E94266D4012690E78C858B5792
       E7529E7A33CFE1B835AF21C4B58235B07A8AF48EB9FE72BCD85A16A16C1C8465
       AD1E7194070A74A0F95AC3BC522E6C901D3827CA5621C202E0E5F9E6ACD05357
       49F2B10282010100B3125FC1F8A41BCEC48348D554B1F1D4B551E1DE920C6A39
       E2F7F6FFD5C98D1254C553FBD16B16F865AF0E405F3FC46F614E5740FD388208
       8923299F6B331701933DC2E00949A417C61515E5671DA2704F2812BFF42E35DA
       BC442D22389E40C360A891D7A0BA37F8A3581154CD06C853B06743EE0A10B961
       BA7F5F5B6326AA067033FC87EB9F0597C154B62C8FE8A0291FCB45AD9DE68A9E
       D6B9F6171FBD09485FB03A24B5CBBEBEBBFC3411CBC3CE022AF19CCE8CE5C7EE
       695F3B64E57032C8ABFD792725E72A3AA8890483FF0BEBEABEF1383FC61616BE
       25994D658CE69F0393E5CFD78DE5A81745143F7BC74907D038A35FD08C060BD6
       DAD492388246EB39028201003A3A37839A14AAEA638ADB559DCF7CAD40E0D2FF
       3F3EACB9F32C1EDDB99A09505DEDDD08C22BF9F425ED8E3F1CF3685E22D480CB
       EA0AF3329F62B7A33F4B2C4127D1041CCA480440BCB9862B15263FF473A62CF5
       FF78D9A79282DFF4F20AB2A025AD2D1ED557A74A45FEE4BC8617C8FBE10ACB6F
       DEF43E0AFE077E564E0DA2FCE8A29C6341564D02562D8399C71E355A008945CA
       DAA3C8C35515BDBBCBB73C023814531D5D880017DEF1D79EA68C66774009396A
       226A426A5BFCC35CB5D2C4718229AC2367BF7D4FB2379093D3607A2EBFBA778C
       C40489622820A790E236BBB62BEAE9961D165D0784FFBA77A2999638D5AA7313
       2BF2E6C334598283CFFA28CD"""
  ]

  PublicKeys = [
    """30820122300D06092A864886F70D01010105000382010F003082010A02820101
       00B7362C6653ED53C35C3AE663DA496C9B834FF34D72DA98FA6DBF4AABA39FCA
       0901F58A1B1D205076D20010151DBCA8FC2693E14D3502320D61E796E9C102C4
       EBB8F50B90616DE7FB8EA0A4BFC89BE542CC86DB7F179B153BC325048BD43A74
       5A203F86B48D54589D4AFBEE128DCAD9C481C157F0AECB1EF4720E0E8535C96C
       318F3B53FEEFDD13774981BDDF6CB60331B2A954E2D60DE05961114A8B05EDF1
       3DD116AE47E930CAC1A56FAFFE5438AB5DB0A88A3563BCB9B4315121FC468531
       7847CA4806722BC74ED9954F409D42CAA3BE028E251FA0218414F2ED4469ED78
       C601C71EF7C68D06BBA24DCDFDC8DCCB1F93A72896756B9CCA840E4188D8D02F
       890203010001""",
    """308201A2300D06092A864886F70D01010105000382018F003082018A02820181
       009E4E6CCBE33B69A9FB6A3CAEADDC47E26AE15E1FF8C56B3126C4C66E549F86
       F0002A1CC3D0169F034825A3683AA0A579D844B415698F6F2AA5907246D911CF
       CD69A5151A78BA5AD803A8FAF0184DAD4BF471469DB91BE951FD12EE5C8047B5
       36984873A4F79BC054BF0E0A4730A1B20C3CF92440B1ECC5FA608213AD823C10
       D9994B3F532FE5FDEF25D6DAE7CDAF1EE7238E70F159BA05684261A49050B8E3
       F37141D13A328A4418168629A5CE8845FBDB70EAF8988617D5200F1D3695E07C
       F72978B220AF30E9832BBCFC02273716D2851D43A0154E16DED7B4975C188141
       1B63ACEEC3EA7E438DB441128BEB77BC7D452C931DC8C03E8A882F85BF6E211E
       B79DC649A2CEF2F1A197EA69C022C6929AA79D9BAB6BF56DC21F7E3A70192F25
       23F8393AC95ADD0C07889F31C4BB2F936C35D2C25F9BDB1DCF131FCC87038C5F
       53898616956CC92FF904ED9DE01202630100E99D7631556C3A335B4E44D74C21
       45F7769E071576CBBFB120850D85C524F0E613705E0EF3F8D2386F4EBF47520F
       B50203010001""",
    """30820222300D06092A864886F70D01010105000382020F003082020A02820201
       0099EBDD4A8DBFD112966F0242CD0D0DFEE9A48572D49ED4F1E8BD52A0892469
       1A6CE53A47140EC84D046DB142E0607733204FD461D8CB58BDBF05E51FFB7785
       4660ED814861429AE54BD682A06F0B3C51FBD7A27D5117862D9EDF6B6A51B4E9
       1F9A973EC3F8EF223EE656B4DA0B1CD41B323EE1ED4BCF88611C7BB11EEC1C7E
       D7D058B1E0F589D3682B25534CDD56F125D0298DD545D26BEB6E1DE1A5411CFE
       2520B066113AE24198BA24BC47D33B44552A1305E21FD6E1E1699DA1DB04975D
       35B27011AE9E613B7D4BD7F8144C00E11CC6704CE65DE9761B4ACE8D1F6516BE
       3B83A8DA3FAC94391DD2FD503342C0D924004615200F40B2BD0430A4472C0BB4
       3F1629E851B5F87ACA7AEF56C06FBF5E2E481DC07CE1A8A06F20ABC88203E2C5
       88AACD1AC9CC8D42C52A37DD6CEC2E4916B3A4DD1CF24B82BC6E02A0B87B6436
       AECA94E271D571A2FC7AEB494F180EAED8DF63B9F906E725447C1E3AC5CE54D9
       96B7AB6E41E2CCA301D901716C886798077C61801BF770A2A20F9E08BE57F9B0
       2C56379D4B8D32DF4D07B3E70F781CAA4147B6F6A01BEC7AD99B07FC5DC8927A
       4DF9B17DFED8B01CCE57F78DD3EB1A408C900024CDB1C5C909F55DC9D8C9E1F3
       8DD52A3DB9287276D556FC1E5CADB7F727A0C74108CF0F8D88948331E024FA6E
       BBB064302E58B4FD3EAD0135CA0BAE5BEB2DC6DD5CAC02EF7A59743F5415109D
       750203010001"""
  ]

  Messages = [
    "sample", "test", "sample", "test", "sample", "test"
  ]

  Signatures = [
    """30768DB2A850D5F3F9044D2C7545C3E3D30B03B6F8159D305F19B1CF939C1336
       DDA83B406D86ECE5170CE922671FCB178FC03DEF87DBA73C002DC7D302FD122F
       1A23BB9F39F21DEBFE42E69A06A0871691B02AEE59772B485ABBF92B99B8E3C8
       F3E0396CD1F197BDD18B9C42684D1A4B91961737CCDA98E40791242ED49D79F5
       02605DC05C3D5106A424ED1D763630864E9E3F448022F411B62F3F5EA87C567B
       7D888B1F5758BD98D366BC4188323986953A42B5A6A3F5AD31F60DF7DE3A1351
       67B714734185DE35599DD53F884DEABCA41614363B596F01BC3EA349717ECF41
       7251F2A93D1737304271F06DF6224A1BA2058B70996EEBC0CE4AF95006F3208C""",
    """1E5217F9A99A084E7DF3B1AA68B32B04FAEE95A8815B40C236241E4B40DA094A
       7A8C768414E9B66298A48F0A3769E2D873077590D9D6A1A613E20003589E7FC7
       F27FC6ECD471B8C50D2ED4D7915F61FC04F82CCD1708DF64AC3666720CA9FF40
       D332199F35AEA377A8F8F12354A25A8A277EF9069A659C1819BD8C97146A7453
       EFFF4274AD0A406B957041ACD2FB892D5009673E50AE6B067C7E906F35A919C6
       7CAEBE2EACA1067E9B76DB8A74AF8416A3C1E0711F92A520AFE4A258ACDB6128
       47B06DF8B6705618D284C4272EDC1C11D1EDDF4D8174DE4F4706034421B0CB82
       70771C40A2020E022886C44F7811AB06A3838B055F8D652104E653A1312B7506""",
    """89D01B4043322ED57F20D6756EAE5295A86AA3503FA66A6AC35E2AABAD78F199
       EC5E85DBD6D43DE03C662CEFA003413434EC890DD58DF8ED6C3167DA9B4DBFD5
       703ADED2544C72E6300A76F0126720F7843A0B0C82CBE220619B3925F94BE8D1
       E6B9455EC9DFE6A133868E6E6893C8868B9DAD5D6F1A49056BD2784B6677A76D
       B0B90152C398890305FC3A37BAAB5253CBC358FD33BC86FBFAC88E136C3EF393
       8C922575C20878FEF8AB0CBD8570654275F9B96801410E13A8BF9F3ED8AAA72F
       5C7A9500A80761EB4462FBD3A0011C660C54301460B63E79F0693352E62DDD7C
       2EFF6522A39EA366A1CE0386EAE546EB373AD8BFE8371DF6D76241FB67215DE0
       3D0A0EC109B2CD7D74BDCBBBD1700F6BA04CD737FB11A2BFDEA5CDC5AA162C73
       26DBFE23D7EEBBCFD2462381BFEFDDC6929E0338CA552181022834F8C869D37B
       4EC5FD00A6AA7D8FDBB77AF226E2CB1D5A01056B3050409F9EE6C04188106E21
       E6EAE8991FB4355BA1037E6792F80F35A99598E493F910439DB7AC6BB211BE3B""",
    """16A0A6913C5FFB44105C25B5C217249BC8A72D9AF0D7C669B66CB3520D131497
       A60EAD1EAE629C3102812FBC17FE681489F4B88705BD9E3DF6587897FF86AE4F
       4C23753BFDB59FCB6723910B087C2BEBA379AB418CE54C2FD98DBD8A64798F48
       9989DE0C3980B2DA1EFF03A98945947DFFAE0053FD7E62C9C1525F5608693FF7
       A359CCA7970143878ED13E510D83B872FDE3E74E869B650728C93146A926D81F
       B56A938E8F76F5D617A814926E54A43819815286B3A929A61A64C1D4D6236FFE
       3A3D6E5D1D77787A80B1EF30FE06F02DABC908C635E9D16CE15D3DD5F3DDEBEE
       F30C2CD930A0835B75889EFCE46868A5CB6D484ABB1178E3867DEDAA81921414
       AA34200E2066C50AC5A9E926E4EB2ABFAD7B1D068E88D7A4EC748420DAE63926
       CF47E8A911B99FA9C9A4016A378B5AEB8B9AA2C92C1836994A9069D10985B394
       7AC24DD27432DE0B4D3D62D9D2EC24CC1F1D9F44B6BFF74085CE3D8E2B23BD3F
       9BD704817EE7DC8E2B07D32A02790C8B40F8286802FA0C0707B1CD98F19DE9AF""",
    """984A8ACD327392DF3C16D504AC152BB7484255A9A8E06EE54F4CE61D017B6908
       11FA8D1845E72073E775A07FE5C8C028B1FC6E9B8349993D69A058DFA233E9FF
       69B2F65D12A80051C823AD81BAA143C958D484E1ED5749F67B21E2D69D7EC6E9
       CB55926C84DCCE0C367672D852A7E42CB049E33DFBB621EA2A66EB5736145D4E
       07FFE255B4248A68801768CF28F877B3E4FABD6D95F11109E0B1025BB917F6DE
       03CC9023D8225537369F39F509C188884F6C1900DE08E623E15A25373BA70F5A
       F00C0375E6601CF93120A3145D6DD0C7D89022AC73FA2C12BE0F78AD280B9BF6
       0DD431F9DD674C2BC092E81BC26A064C9E38614D9E464B40204C27255F69089F
       9B795E640D3A18159C39B3E1529F3AF0718322505F42331271F4AAA66F46F0C3
       9BA01FB86A7B93AA727379F0C1F9AD08C7AC9B1CCA9F80B5569A292C589E8A97
       236E8D29AAC10B698960D3183DE3E82CAA642C004DF65C99F6018D8EE42DF17F
       176AD36B63A09CFB2F7809DBDE52B4D09AF5310833B6819FBB88FDE1288320E9
       4ABD50457654A1C7DD8E858743E04928388C95979814BE22FDE99B4914BC452A
       114DBD8F053EA97C5616C46D840D3251125C49A363D29AA31063BF5004D18724
       CCD2E6533B92608B283EC59937BB267D918B9EAC14AF8BB522D7494CFEE859EE
       07C0602C8683E4E658D585EBA488824A7BBFA32D7A31F5C46CBCE662998C1C75""",
    """7B154A8A46ADF18B09E4A499391A40E798F63BC314584D701CB68923102F96E0
       6F85314BD1F52E98AC24332C42AB15C116C165BF2F48C9116796D4B2FF0A1DA5
       74669EE1FF51196BDFFBAECD67F97CFC9001F71E0840E5484E77E15C21CC66BD
       B75593424A313E9E6828952ACC606DF0698491F6EF66E55DCBF16F1B7AC406C6
       9B3AAF6554536802A33CE991365E18C50C407CF7C7A35AE43BB51E056C7D629B
       5558E32ADC25E4CDB9FF5EEB71A30C907F8FFA8DFBB428EEFD6ECB70605DB498
       B4F7EF081A4AE5B37BE32788C556F99D97956B1F0D3EF7932E5CA2F0A1C02764
       09C979A06060A816EEDA400D01413E375434C9E083EE436BC73CE71BBE626102
       19657852B3A5F9003DC72317A06CC4AF7EBD70E4CE90A2481C337C1E74BCC219
       25FECA4765C24AA3DDF05D0A49BD66264A8E156D15CCEE08FC3B94776DBCCDFE
       4E55DE8B67DF40751F1CFBE71A74600C61954E21A021A4182152421384C9A0C8
       F7A3BAED39812B536076CA482C1C83C10153E1739648C5384134E58EB3F72D36
       29E98C648410A8107EEADA3FAFD32B5AEF12D4E991EAA8364FDFF5AE1C9F34ED
       28B120B402C92717B0D480B5DE8D53CADC0903296614158F0DFC38505762C829
       9DC529573BBF8C149D5E1E8745F9B72D4E68607C859327AF54D0013F37542236
       ACB51807206B8332127E3692269013B96F0CABD95D7431805E48176ADC5D1366"""
  ]

let rng = newRng()

type
  RsaPrivateKey = rsa.RsaPrivateKey
  RsaPublicKey = rsa.RsaPublicKey

suite "RSA 2048/3072/4096 test suite":
  test "[rsa2048] Private key serialize/deserialize test":
    var rkey1, rkey2: RsaPrivateKey
    var skey2 = newSeq[byte](4096)
    var key = RsaPrivateKey.random(rng[], 2048).expect("random failed")
    var skey1 = key.getBytes().expect("bytes")
    check key.toBytes(skey2).expect("bytes") > 0
    check:
      rkey1.init(skey1).isOk()
      rkey2.init(skey2).isOk()
    var rkey3 = RsaPrivateKey.init(skey1).expect("key initialization")
    var rkey4 = RsaPrivateKey.init(skey2).expect("key initialization")
    check:
      rkey1 == key
      rkey2 == key
      rkey3 == key
      rkey4 == key

  test "[rsa3072] Private key serialize/deserialize test":
    var rkey1, rkey2: RsaPrivateKey
    var skey2 = newSeq[byte](4096)
    var key = RsaPrivateKey.random(rng[], 3072).expect("random failed")
    var skey1 = key.getBytes().expect("bytes")
    check key.toBytes(skey2).expect("bytes") > 0
    check:
      rkey1.init(skey1).isOk()
      rkey2.init(skey2).isOk()
    var rkey3 = RsaPrivateKey.init(skey1).expect("key initialization")
    var rkey4 = RsaPrivateKey.init(skey2).expect("key initialization")
    check:
      rkey1 == key
      rkey2 == key
      rkey3 == key
      rkey4 == key

  test "[rsa4096] Private key serialize/deserialize test":
    # This test is too slow to run in debug mode.
    when defined(release):
      var rkey1, rkey2: RsaPrivateKey
      var skey2 = newSeq[byte](4096)
      var key = RsaPrivateKey.random(rng[], 4096).expect("random failed")
      var skey1 = key.getBytes().expect("bytes")
      check key.toBytes(skey2).expect("bytes") > 0
      check:
        rkey1.init(skey1).isOk()
        rkey2.init(skey2).isOk()
      var rkey3 = RsaPrivateKey.init(skey1).expect("key initialization")
      var rkey4 = RsaPrivateKey.init(skey2).expect("key initialization")
      check:
        rkey1 == key
        rkey2 == key
        rkey3 == key
        rkey4 == key
    else:
      skip()

  test "[rsa2048] Public key serialize/deserialize test":
    var rkey1, rkey2: RsaPublicKey
    var skey2 = newSeq[byte](4096)
    var pair = RsaKeyPair.random(rng[], 2048).expect("random failed")
    var skey1 = pair.pubkey.getBytes().expect("bytes")
    check:
      pair.pubkey.toBytes(skey2).expect("bytes") > 0
      rkey1.init(skey1).isOk()
      rkey2.init(skey2).isOk()
    var rkey3 = RsaPublicKey.init(skey1).expect("key initialization")
    var rkey4 = RsaPublicKey.init(skey2).expect("key initialization")
    check:
      rkey1 == pair.pubkey
      rkey2 == pair.pubkey
      rkey3 == pair.pubkey
      rkey4 == pair.pubkey

  test "[rsa3072] Public key serialize/deserialize test":
    var rkey1, rkey2: RsaPublicKey
    var skey2 = newSeq[byte](4096)
    var pair = RsaKeyPair.random(rng[], 3072).expect("random failed")
    var skey1 = pair.pubkey.getBytes().expect("bytes")
    check:
      pair.pubkey.toBytes(skey2).expect("bytes") > 0
      rkey1.init(skey1).isOk()
      rkey2.init(skey2).isOk()
    var rkey3 = RsaPublicKey.init(skey1).expect("key initialization")
    var rkey4 = RsaPublicKey.init(skey2).expect("key initialization")
    check:
      rkey1 == pair.pubkey
      rkey2 == pair.pubkey
      rkey3 == pair.pubkey
      rkey4 == pair.pubkey

  test "[rsa4096] Public key serialize/deserialize test":
    when defined(release):
      var rkey1, rkey2: RsaPublicKey
      var skey2 = newSeq[byte](4096)
      var pair = RsaKeyPair.random(rng[], 4096).expect("random failed")
      var skey1 = pair.pubkey.getBytes().expect("bytes")
      check:
        pair.pubkey.toBytes(skey2).expect("bytes") > 0
        rkey1.init(skey1).isOk()
        rkey2.init(skey2).isOk()
      var rkey3 = RsaPublicKey.init(skey1).expect("key initialization")
      var rkey4 = RsaPublicKey.init(skey2).expect("key initialization")
      check:
        rkey1 == pair.pubkey
        rkey2 == pair.pubkey
        rkey3 == pair.pubkey
        rkey4 == pair.pubkey
    else:
      skip()

  test "[rsa2048] Generate/Sign/Serialize/Deserialize/Verify test":
    var message = "message to sign"
    var kp = RsaKeyPair.random(rng[], 2048).expect("RsaPrivateKey.random failed")
    var sig = kp.seckey.sign(message).expect("signature")
    var sersk = kp.seckey.getBytes().expect("bytes")
    var serpk = kp.pubkey.getBytes().expect("bytes")
    var sersig = sig.getBytes().expect("bytes")
    discard RsaPrivateKey.init(sersk).expect("key initialization")
    var pubkey = RsaPublicKey.init(serpk).expect("key initialization")
    var csig = RsaSignature.init(sersig).expect("key initialization")
    check csig.verify(message, pubkey) == true
    let error = csig.buffer.high
    csig.buffer[error] = not(csig.buffer[error])
    check csig.verify(message, pubkey) == false

  test "[rsa3072] Generate/Sign/Serialize/Deserialize/Verify test":
    var message = "message to sign"
    var kp = RsaKeyPair.random(rng[], 3072).expect("RsaPrivateKey.random failed")
    var sig = kp.seckey.sign(message).expect("signature")
    var sersk = kp.seckey.getBytes().expect("bytes")
    var serpk = kp.pubkey.getBytes().expect("bytes")
    var sersig = sig.getBytes().expect("bytes")
    discard RsaPrivateKey.init(sersk).expect("key initialization")
    var pubkey = RsaPublicKey.init(serpk).expect("key initialization")
    var csig = RsaSignature.init(sersig).expect("key initialization")
    check csig.verify(message, pubkey) == true
    let error = csig.buffer.high
    csig.buffer[error] = not(csig.buffer[error])
    check csig.verify(message, pubkey) == false

  test "[rsa4096] Generate/Sign/Serialize/Deserialize/Verify test":
    when defined(release):
      var message = "message to sign"
      var kp = RsaKeyPair.random(rng[], 4096).expect("RsaPrivateKey.random failed")
      var sig = kp.seckey.sign(message).expect("signature")
      var sersk = kp.seckey.getBytes().expect("bytes")
      var serpk = kp.pubkey.getBytes().expect("bytes")
      var sersig = sig.getBytes().expect("bytes")
      discard RsaPrivateKey.init(sersk).expect("key initialization")
      var pubkey = RsaPublicKey.init(serpk).expect("key initialization")
      var csig = RsaSignature.init(sersig).expect("key initialization")
      check csig.verify(message, pubkey) == true
      let error = csig.buffer.high
      csig.buffer[error] = not(csig.buffer[error])
      check csig.verify(message, pubkey) == false
    else:
      skip()

  test "[rsa2048] Test vectors":
    var prvser = fromHex(stripSpaces(PrivateKeys[0]))
    var pubser = fromHex(stripSpaces(PublicKeys[0]))
    var seckey = RsaPrivateKey.init(prvser).expect("key initialization")
    var pubkey = RsaPublicKey.init(pubser).expect("key initialization")
    check:
      seckey.getBytes().expect("bytes") == prvser
    var cpubkey = seckey.getPublicKey()
    check:
      pubkey == cpubkey
      pubkey.getBytes().expect("bytes") == cpubkey.getBytes().expect("bytes")
      pubkey.getBytes().expect("bytes") == pubser

    for i in 0..1:
      var sigser = fromHex(stripSpaces(Signatures[i]))
      var sig = RsaSignature.init(sigser).expect("key initialization")
      var csig = seckey.sign(Messages[i]).expect("signature")
      check:
        sig == csig
        sig.getBytes().expect("bytes") == csig.getBytes().expect("bytes")
        csig.verify(Messages[i], pubkey) == true
        csig.verify(Messages[(i + 1) mod 2], pubkey) == false

  test "[rsa3072] Test vectors":
    var prvser = fromHex(stripSpaces(PrivateKeys[1]))
    var pubser = fromHex(stripSpaces(PublicKeys[1]))
    var seckey = RsaPrivateKey.init(prvser).expect("key initialization")
    var pubkey = RsaPublicKey.init(pubser).expect("key initialization")
    check:
      seckey.getBytes().expect("bytes") == prvser
    var cpubkey = seckey.getPublicKey()
    check:
      pubkey == cpubkey
      pubkey.getBytes().expect("bytes") == cpubkey.getBytes().expect("bytes")
      pubkey.getBytes().expect("bytes") == pubser

    for i in 0..1:
      var sigser = fromHex(stripSpaces(Signatures[2 + i]))
      var sig = RsaSignature.init(sigser).expect("key initialization")
      var csig = seckey.sign(Messages[2 + i]).expect("signature")
      check:
        sig == csig
        sig.getBytes().expect("bytes") == csig.getBytes().expect("bytes")
        csig.verify(Messages[2 + i], pubkey) == true
        csig.verify(Messages[2 + (i + 1) mod 2], pubkey) == false

  test "[rsa4096] Test vectors":
    var prvser = fromHex(stripSpaces(PrivateKeys[2]))
    var pubser = fromHex(stripSpaces(PublicKeys[2]))
    var seckey = RsaPrivateKey.init(prvser).expect("key initialization")
    var pubkey = RsaPublicKey.init(pubser).expect("key initialization")
    check:
      seckey.getBytes().expect("bytes") == prvser
    var cpubkey = seckey.getPublicKey()
    check:
      pubkey == cpubkey
      pubkey.getBytes().expect("bytes") == cpubkey.getBytes().expect("bytes")
      pubkey.getBytes().expect("bytes") == pubser

    for i in 0..1:
      var sigser = fromHex(stripSpaces(Signatures[4 + i]))
      var sig = RsaSignature.init(sigser).expect("key initialization")
      var csig = seckey.sign(Messages[4 + i]).expect("signature")
      check:
        sig == csig
        sig.getBytes().expect("bytes") == csig.getBytes().expect("bytes")
        csig.verify(Messages[4 + i], pubkey) == true
        csig.verify(Messages[4 + (i + 1) mod 2], pubkey) == false

  test "[rsa512] not allowed test":
    var key1 = RsaPrivateKey.random(rng[], 512)
    let prvser = fromHex(stripSpaces(NotAllowedPrivateKeys[0]))
    let pubser = fromHex(stripSpaces(NotAllowedPublicKeys[0]))
    var key2 = RsaPrivateKey.init(prvser)
    var key3 = RsaPublicKey.init(pubser)
    check:
      key1.isErr() == true
      key2.isErr() == true
      key3.isErr() == true
      key1.error == RsaLowSecurityError
      key2.error == RsaKeyIncorrectError
      key3.error == RsaKeyIncorrectError

  test "[rsa1024] not allowed test":
    var key1 = RsaPrivateKey.random(rng[], 1024)
    let prvser = fromHex(stripSpaces(NotAllowedPrivateKeys[1]))
    let pubser = fromHex(stripSpaces(NotAllowedPublicKeys[1]))
    var key2 = RsaPrivateKey.init(prvser)
    var key3 = RsaPublicKey.init(pubser)
    check:
      key1.isErr() == true
      key2.isErr() == true
      key3.isErr() == true
      key1.error == RsaLowSecurityError
      key2.error == RsaKeyIncorrectError
      key3.error == RsaKeyIncorrectError
