import chronos
import algorithm
from strutils import toHex

const
  MaxAdapterAddressLength* = 8

type
  InterfaceType* = enum
    IfError = 0, # This is workaround element for ProoveInit warnings.
    IfOther = 1,
    IfRegular1822 = 2,
    IfHdh1822 = 3,
    IfDdnX25 = 4,
    IfRfc877X25 = 5,
    IfEthernetCsmacd = 6,
    IfIso88023Csmacd = 7,
    IfIso88024TokenBus = 8,
    IfIso88025TokenRing = 9,
    IfIso88026MAN = 10,
    IfStarlan = 11,
    IfProteon10Mbit = 12,
    IfProteon80Mbit = 13,
    IfHyperChannel = 14,
    IfFddi = 15,
    IfLapB = 16,
    IfSdlc = 17,
    IfDs1 = 18,
    IfE1 = 19,
    IfBasicIsdn = 20,
    IfPrimaryIsdn = 21,
    IfPropPoint2PointSerial = 22,
    IfPpp = 23,
    IfSoftwareLoopback = 24,
    IfEon = 25,
    IfEthernet3Mbit = 26,
    IfNsip = 27,
    IfSlip = 28,
    IfUltra = 29,
    IfDs3 = 30,
    IfSip = 31,
    IfFrameRelay = 32,
    IfRs232 = 33,
    IfPara = 34,
    IfArcNet = 35,
    IfArcNetPlus = 36,
    IfAtm = 37,
    IfMioX25 = 38,
    IfSonet = 39,
    IfX25Ple = 40,
    IfIso88022Llc = 41,
    IfLocalTalk = 42,
    IfSmdsDxi = 43,
    IfFrameRelayService = 44,
    IfV35 = 45,
    IfHssi = 46,
    IfHippi = 47,
    IfModem = 48,
    IfAal5 = 49,
    IfSonetPath = 50,
    IfSonetVt = 51,
    IfSmdsIcip = 52,
    IfPropVirtual = 53,
    IfPropMultiplexor = 54,
    IfIeee80212 = 55,
    IfFibreChannel = 56,
    IfHippiInterface = 57,
    IfFrameRelayInterconnect = 58,
    IfAflane8023 = 59,
    IfAflane8025 = 60,
    IfCctemul = 61,
    IfFastEther = 62,
    IfIsdn = 63,
    IfV11 = 64,
    IfV36 = 65,
    IfG70364K = 66,
    IfG7032MB = 67,
    IfQllc = 68,
    IfFastEtherFx = 69,
    IfChannel = 70,
    IfIeee80211 = 71,
    IfIbm370Parchan = 72,
    IfEscon = 73,
    IfDlsw = 74,
    IfIsdnS = 75,
    IfIsdnU = 76,
    IfLapD = 77,
    IfIpSwitch = 78,
    IfRsrb = 79,
    IfAtmLogical = 80,
    IfDs0 = 81,
    IfDs0Bundle = 82,
    IfBsc = 83,
    IfAsync = 84,
    IfCnr = 85,
    IfIso88025rDtr = 86,
    IfEplrs = 87,
    IfArap = 88,
    IfPropCnls = 89,
    IfHostPad = 90,
    IfTermPad = 91,
    IfFrameRelayMpi = 92,
    IfX213 = 93,
    IfAdsl = 94,
    IfRadsl = 95,
    IfSdsl = 96,
    IfVdsl = 97,
    IfIso88025Crfprint = 98,
    IfMyrInet = 99,
    IfVoiceEm = 100,
    IfVoiceFxo = 101,
    IfVoiceFxs = 102,
    IfVoiceEncap = 103,
    IfVoiceOverip = 104,
    IfAtmDxi = 105,
    IfAtmFuni = 106,
    IfAtmIma = 107,
    IfPppMultilinkBundle = 108,
    IfIpoverCdlc = 109,
    IfIpoverClaw = 110,
    IfStackToStack = 111,
    IfVirtualIpAddress = 112,
    IfMpc = 113,
    IfIpoverAtm = 114,
    IfIso88025Fiber = 115,
    IfTdlc = 116,
    IfGigabitEthernet = 117,
    IfHdlc = 118,
    IfLapF = 119,
    IfV37 = 120,
    IfX25Mlp = 121,
    IfX25HuntGroup = 122,
    IfTransPhdlc = 123,
    IfInterleave = 124,
    IfFast = 125,
    IfIp = 126,
    IfDocScableMaclayer = 127,
    IfDocScableDownstream = 128,
    IfDocScableUpstream = 129,
    IfA12MppSwitch = 130,
    IfTunnel = 131,
    IfCoffee = 132,
    IfCes = 133,
    IfAtmSubInterface = 134,
    IfL2Vlan = 135,
    IfL3IpVlan = 136,
    IfL3IpxVlan = 137,
    IfDigitalPowerline = 138,
    IfMediaMailOverIp = 139,
    IfDtm = 140,
    IfDcn = 141,
    IfIpForward = 142,
    IfMsdsl = 143,
    IfIeee1394 = 144,
    IfIfGsn = 145,
    IfDvbrccMaclayer = 146,
    IfDvbrccDownstream = 147,
    IfDvbrccUpstream = 148,
    IfAtmVirtual = 149,
    IfMplsTunnel = 150,
    IfSrp = 151,
    IfVoiceOverAtm = 152,
    IfVoiceOverFrameRelay = 153,
    IfIdsl = 154,
    IfCompositeLink = 155,
    IfSs7SigLink = 156,
    IfPropWirelessP2p = 157,
    IfFrForward = 158,
    IfRfc1483 = 159,
    IfUsb = 160,
    IfIeee8023AdLag = 161,
    IfBgpPolicyAccounting = 162,
    IfFrf16MfrBundle = 163,
    IfH323Gatekeeper = 164,
    IfH323Proxy = 165,
    IfMpls = 166,
    IfMfSigLink = 167,
    IfHdsl2 = 168,
    IfShdsl = 169,
    IfDs1Fdl = 170,
    IfPos = 171,
    IfDvbAsiIn = 172,
    IfDvbAsiOut = 173,
    IfPlc = 174,
    IfNfas = 175,
    IfTr008 = 176,
    IfGr303Rdt = 177,
    IfGr303Idt = 178,
    IfIsup = 179,
    IfPropDocsWirelessMaclayer = 180,
    IfPropDocsWirelessDownstream = 181,
    IfPropDocsWirelessUpstream = 182,
    IfHiperLan2 = 183,
    IfPropBwaP2mp = 184,
    IfSonetOverheadChannel = 185,
    IfDigitalWrapperOverheadChannel = 186,
    IfAal2 = 187,
    IfRadioMac = 188,
    IfAtmRadio = 189,
    IfImt = 190,
    IfMvl = 191,
    IfReachDsl = 192,
    IfFrDlciEndpt = 193,
    IfAtmVciEndpt = 194,
    IfOpticalChannel = 195,
    IfOpticalTransport = 196,
    IfIeee80216Wman = 237,
    IfWwanPp = 243,
    IfWwanPp2 = 244,
    IfIeee802154 = 259,
    IfXboxWireless = 281

  InterfaceState* = enum
    StatusError = 0,  # This is workaround element for ProoveInit warnings.
    StatusUp,
    StatusDown,
    StatusTesting,
    StatusUnknown,
    StatusDormant,
    StatusNotPresent,
    StatusLowerLayerDown

  InterfaceAddress* = object
    ifaddr*: TransportAddress
    prefix*: int

  NetworkInterface* = object
    ifIndex*: int
    ifType*: InterfaceType
    name*: string
    desc*: string
    mtu*: int
    flags*: uint64
    state*: InterfaceState
    mac*: array[MaxAdapterAddressLength, byte]
    maclen*: int
    addresses*: seq[InterfaceAddress]

proc host*(ifa: InterfaceAddress): TransportAddress =
  ## Return host address for ``ifa``.
  result = ifa.ifaddr

template setBroadcast(b, nby, nbi) =
  if nbi == 0:
    for i in nby..<len(b):
      b[i] = 0xFF'u8
  else:
    let bcast = not cast[byte](0xFF'u8 shl (8 - nbi))
    b[nby] = b[nby] or bcast
    for i in (nby + 1)..<len(b):
      b[i] = 0xFF'u8

template setNetwork(b, nby, nbi) =
  if nbi == 0:
    for i in nby..<len(b):
      b[i] = 0x00'u8
  else:
    let mask = cast[byte](0xFF'u8 shl (8 - nbi))
    b[nby] = b[nby] and mask
    for i in (nby + 1)..<len(b):
      b[i] = 0x00'u8

template setNetmask(b, nby, nbi) =
  var mask: byte
  for i in 0..<nby:
    b[i] = 0xFF'u8
  if nbi > 0:
    mask = cast[byte](0xFF'u8 shl (8 - nbi))
  if nby < len(b):
    b[nby] = b[nby] or mask
  for i in (nby + 1)..<len(b):
    b[i] = 0x00'u8

proc broadcast*(ifa: InterfaceAddress): TransportAddress =
  ## Return broadcast address for ``ifa``.
  let nbytes = ifa.prefix div 8
  let nbits = ifa.prefix mod 8
  result = ifa.ifaddr
  if result.family == AddressFamily.IPv4:
    setBroadcast(result.address_v4, nbytes, nbits)
  elif result.family == AddressFamily.IPv6:
    setBroadcast(result.address_v6, nbytes, nbits)

proc network*(ifa: InterfaceAddress): TransportAddress =
  ## Return network address for ``ifa``.
  let nbytes = ifa.prefix div 8
  let nbits = ifa.prefix mod 8
  result = ifa.ifaddr
  if result.family == AddressFamily.IPv4:
    setNetwork(result.address_v4, nbytes, nbits)
  elif result.family == AddressFamily.IPv6:
    setNetwork(result.address_v6, nbytes, nbits)

proc netmask*(ifa: InterfaceAddress): TransportAddress =
  ## Return network mask for ``ifa``.
  let nbytes = ifa.prefix div 8
  let nbits = ifa.prefix mod 8
  result = TransportAddress(family: ifa.ifaddr.family)
  if result.family == AddressFamily.IPv4:
    setNetmask(result.address_v4, nbytes, nbits)
  elif result.family == AddressFamily.IPv6:
    setNetmask(result.address_v6, nbytes, nbits)

proc hostMin*(ifa: InterfaceAddress): TransportAddress =
  ## Return minimum allowed host address for ``ifa``
  result = ifa.network()
  if result.family == AddressFamily.IPv4:
    let last = len(result.address_v4) - 1
    result.address_v4[last] = result.address_v4[last] + 1
  elif result.family == AddressFamily.IPv6:
    let last = len(result.address_v6) - 1
    result.address_v6[last] = result.address_v6[last] + 1

proc hostMax*(ifa: InterfaceAddress): TransportAddress =
  ## Return maximum allowed host address for ``ifa``.
  result = ifa.broadcast()
  if result.family == AddressFamily.IPv4:
    let last = len(result.address_v4) - 1
    result.address_v4[last] = result.address_v4[last] - 1
  elif result.family == AddressFamily.IPv6:
    let last = len(result.address_v6) - 1
    result.address_v6[last] = result.address_v6[last] - 1

proc init*(ift: typedesc[InterfaceAddress], address: TransportAddress,
           prefix: int): InterfaceAddress =
  ## Initialize ``InterfaceAddress`` using ``address`` and prefix length
  ## ``prefix``.
  result.ifaddr = address
  result.prefix = prefix

proc `$`*(ifa: InterfaceAddress): string =
  ## Return string representation of ``ifa``.
  if ifa.ifaddr.family == AddressFamily.IPv4:
    var a = IpAddress(
      family: IpAddressFamily.IPv4,
      address_v4: ifa.ifaddr.address_v4
    )
    result = $a
    result.add("/")
    result.add($int(ifa.prefix))
  elif ifa.ifaddr.family == AddressFamily.IPv6:
    var a = IpAddress(family: IpAddressFamily.IPv6,
                      address_v6: ifa.ifaddr.address_v6)
    result = $a
    result.add("/")
    result.add($int(ifa.prefix))

proc `$`*(iface: NetworkInterface): string =
  ## Return string representation of network interface ``iface``.
  result = $iface.ifIndex
  if len(result) == 1:
    result.add(".  ")
  else:
    result.add(". ")
  result.add(iface.name)
  when defined(windows):
    result.add(" [")
    result.add(iface.desc)
    result.add("]")
  result.add(": flags = ")
  result.add($iface.flags)
  result.add(" mtu ")
  result.add($iface.mtu)
  result.add(" state ")
  result.add($iface.state)
  result.add("\n    ")
  result.add($iface.ifType)
  result.add(" ")
  if iface.maclen > 0:
    for i in 0..<iface.maclen:
      result.add(toHex(iface.mac[i]))
      if i < iface.maclen - 1:
        result.add(":")
  for item in iface.addresses:
    result.add("\n    ")
    if item.ifaddr.family == AddressFamily.IPv4:
      result.add("inet ")
    elif item.ifaddr.family == AddressFamily.IPv6:
      result.add("inet6 ")
    result.add($item)
    result.add(" netmask ")
    result.add($(item.netmask().address()))
    result.add(" brd ")
    result.add($(item.broadcast().address()))

proc cmp*(a, b: NetworkInterface): int =
  result = cmp(a.ifIndex, b.ifIndex)

when defined(linux):
  import posix

  const
    AF_NETLINK = cint(16)
    AF_PACKET = cint(17)
    NETLINK_ROUTE = cint(0)
    NLMSG_ALIGNTO = 4'u
    RTA_ALIGNTO = 4'u
    RTM_GETLINK = 18
    RTM_GETADDR = 22
    NLM_F_REQUEST = 1
    NLM_F_ROOT = 0x100
    NLM_F_MATCH = 0x200
    NLM_F_DUMP = NLM_F_ROOT or NLM_F_MATCH
    IFLIST_REPLY_BUFFER = 8192
    InvalidSocketHandle = SocketHandle(-1)
    NLMSG_DONE = 0x03
    NLMSG_MIN_TYPE = 0x10
    NLMSG_ERROR = 0x02

    IFLA_ADDRESS = 1
    IFLA_IFNAME = 3
    IFLA_MTU = 4
    IFLA_OPERSTATE = 16

    IFA_ADDRESS = 1
    IFA_LOCAL = 2
    IFA_BROADCAST = 4

    # ARPHRD_NETROM = 0
    ARPHRD_ETHER = 1
    ARPHRD_EETHER = 2
    # ARPHRD_AX25 = 3
    # ARPHRD_PRONET = 4
    # ARPHRD_CHAOS = 5
    # ARPHRD_IEEE802 = 6
    ARPHRD_ARCNET = 7
    # ARPHRD_APPLETLK = 8
    # ARPHRD_DLCI = 15
    ARPHRD_ATM = 19
    # ARPHRD_METRICOM = 23
    ARPHRD_IEEE1394 = 24
    # ARPHRD_EUI64 = 27
    # ARPHRD_INFINIBAND = 32
    ARPHRD_SLIP = 256
    ARPHRD_CSLIP = 257
    ARPHRD_SLIP6 = 258
    ARPHRD_CSLIP6 = 259
    # ARPHRD_RSRVD = 260
    # ARPHRD_ADAPT = 264
    # ARPHRD_ROSE = 270
    # ARPHRD_X25 = 271
    # ARPHRD_HWX25 = 272
    # ARPHRD_CAN = 280
    ARPHRD_PPP = 512
    ARPHRD_CISCO = 513
    ARPHRD_HDLC = ARPHRD_CISCO
    ARPHRD_LAPB = 516
    # ARPHRD_DDCMP = 517
    # ARPHRD_RAWHDLC = 518
    # ARPHRD_TUNNEL = 768
    # ARPHRD_TUNNEL6 = 769
    ARPHRD_FRAD = 770
    # ARPHRD_SKIP = 771
    ARPHRD_LOOPBACK = 772
    # ARPHRD_LOCALTLK = 773
    # ARPHRD_FDDI = 774
    # ARPHRD_BIF = 775
    # ARPHRD_SIT = 776
    # ARPHRD_IPDDP = 777
    # ARPHRD_IPGRE = 778
    # ARPHRD_PIMREG = 779
    ARPHRD_HIPPI = 780
    # ARPHRD_ASH = 781
    # ARPHRD_ECONET = 782
    # ARPHRD_IRDA = 783
    # ARPHRD_FCPP = 784
    # ARPHRD_FCAL = 785
    # ARPHRD_FCPL = 786
    # ARPHRD_FCFABRIC = 787
    # ARPHRD_IEEE802_TR = 800
    ARPHRD_IEEE80211 = 801
    ARPHRD_IEEE80211_PRISM = 802
    ARPHRD_IEEE80211_RADIOTAP = 803
    # ARPHRD_IEEE802154 = 804
    # ARPHRD_IEEE802154_MONITOR = 805
    # ARPHRD_PHONET = 820
    # ARPHRD_PHONET_PIPE = 821
    # ARPHRD_CAIF = 822
    # ARPHRD_IP6GRE = 823
    # ARPHRD_NETLINK = 824
    # ARPHRD_6LOWPAN = 825
    # ARPHRD_VOID = 0xFFFF
    # ARPHRD_NONE = 0xFFFE

  type
    SockAddr_nl = object
      family: cushort
      pad: cushort
      pid: uint32
      groups: uint32

    NlMsgHeader = object
      nlmsg_len: uint32
      nlmsg_type: uint16
      nlmsg_flags: uint16
      nlmsg_seq: uint32
      nlmsg_pid: uint32

    IfInfoMessage = object
      ifi_family: cuchar
      ifi_pad: cuchar
      ifi_type: cushort
      ifi_index: cint
      ifi_flags: cuint
      ifi_change: cuint

    IfAddrMessage = object
      ifa_family: cuchar
      ifa_prefixlen: cuchar
      ifa_flags: cuchar
      ifa_scope: cuchar
      ifa_index: uint32

    RtAttr = object
      rta_len: cushort
      rta_type: cushort

    RtGenMsg = object
      rtgen_family: byte

    NLReq = object
      hdr: NlMsgHeader
      msg: RtGenMsg

  template NLMSG_ALIGN(length: uint): uint =
    (length + NLMSG_ALIGNTO - 1) and not(NLMSG_ALIGNTO - 1)

  template NLMSG_HDRLEN(): int =
    int(NLMSG_ALIGN(uint(sizeof(NlMsgHeader))))

  template NLMSG_LENGTH(length: int): uint32 =
    uint32(NLMSG_HDRLEN() + length)

  proc NLMSG_OK(nlh: ptr NlMsgHeader, length: int): bool {.inline.} =
    result = (length >= int(sizeof(NlMsgHeader))) and
             (nlh.nlmsg_len >= uint32(sizeof(NlMsgHeader))) and
             (nlh.nlmsg_len <= uint32(length))

  proc NLMSG_NEXT(nlh: ptr NlMsgHeader,
                  length: var int): ptr NlMsgHeader {.inline.} =
    length = length - int(NLMSG_ALIGN(uint(nlh.nlmsg_len)))
    result = cast[ptr NlMsgHeader](cast[uint](nlh) +
                                   cast[uint](NLMSG_ALIGN(uint(nlh.nlmsg_len))))

  proc NLMSG_DATA(nlh: ptr NlMsgHeader): ptr byte {.inline.} =
    result = cast[ptr byte](cast[uint](nlh) + NLMSG_LENGTH(0))


  template RTA_HDRLEN(): int =
    int(RTA_ALIGN(uint(sizeof(RtAttr))))

  template RTA_LENGTH(length: int): uint =
    uint(RTA_HDRLEN()) + uint(length)

  template RTA_ALIGN*(length: uint): uint =
    (length + RTA_ALIGNTO - 1) and not(RTA_ALIGNTO - 1)

  template RTA_PAYLOAD*(length: uint): uint =
    length - RTA_LENGTH(0)

  proc IFLA_RTA(r: ptr byte): ptr RtAttr {.inline.} =
    cast[ptr RtAttr](cast[uint](r) + NLMSG_ALIGN(uint(sizeof(IfInfoMessage))))

  proc IFA_RTA(r: ptr byte): ptr RtAttr {.inline.} =
    cast[ptr RtAttr](cast[uint](r) + NLMSG_ALIGN(uint(sizeof(IfAddrMessage))))

  proc RTA_OK(rta: ptr RtAttr, length: int): bool {.inline.} =
    result = length >= sizeof(RtAttr) and
             rta.rta_len >= cushort(sizeof(RtAttr)) and
             rta.rta_len <= cushort(length)

  proc RTA_NEXT(rta: ptr RtAttr, length: var int): ptr RtAttr {.inline.} =
    length = length - int(RTA_ALIGN(uint(rta.rta_len)))
    result = cast[ptr RtAttr](cast[uint](rta) +
                              cast[uint](RTA_ALIGN(uint(rta.rta_len))))

  proc RTA_DATA(rta: ptr RtAttr): ptr byte {.inline.} =
    result = cast[ptr byte](cast[uint](rta) + RTA_LENGTH(0))

  proc toInterfaceState(it: cint, flags: cuint): InterfaceState  {.inline.} =
    case it
    of 1:
      result = StatusNotPresent
    of 2:
      result = StatusDown
    of 3:
      result = StatusLowerLayerDown
    of 4:
      result = StatusTesting
    of 5:
      result = StatusDormant
    of 6:
      result = StatusUp
    else:
      result = StatusUnknown

  proc toInterfaceType(ft: uint32): InterfaceType {.inline.} =
    case ft
    of ARPHRD_ETHER, ARPHRD_EETHER:
      result = IfEthernetCsmacd
    of ARPHRD_LOOPBACK:
      result = IfSoftwareLoopback
    of 787..799:
      result = IfFibreChannel
    of ARPHRD_PPP:
      result = IfPpp
    of ARPHRD_SLIP, ARPHRD_CSLIP, ARPHRD_SLIP6, ARPHRD_CSLIP6:
      result = IfSlip
    of ARPHRD_IEEE1394:
      result = IfIeee1394
    of ARPHRD_IEEE80211, ARPHRD_IEEE80211_PRISM, ARPHRD_IEEE80211_RADIOTAP:
      result = IfIeee80211
    of ARPHRD_ATM:
      result = IfAtm
    of ARPHRD_HDLC:
      result = IfHdlc
    of ARPHRD_HIPPI:
      result = IfHippiInterface
    of ARPHRD_ARCNET:
      result = IfArcNet
    of ARPHRD_LAPB:
      result = IfLapB
    of ARPHRD_FRAD:
      result = IfFrameRelay
    else:
      result = IfOther

  proc createNetlinkSocket(pid: Pid): SocketHandle =
    var address: SockAddr_nl
    address.family = cushort(AF_NETLINK)
    address.groups = 0
    address.pid = cast[uint32](pid)
    result = posix.socket(AF_NETLINK, posix.SOCK_DGRAM, NETLINK_ROUTE)
    if result != SocketHandle(-1):
      if posix.bindSocket(result, cast[ptr SockAddr](addr address),
                          Socklen(sizeof(SockAddr_nl))) != 0:
        discard posix.close(result)
        result = SocketHandle(-1)

  proc sendNetlinkMessage(fd: SocketHandle, pid: Pid, seqno: uint32,
                          ntype: uint16, nflags: uint16): bool =
    var
      rmsg: Tmsghdr
      iov: IOVec
      req: NLReq
      address: SockAddr_nl
    address.family = cushort(AF_NETLINK)
    req.hdr.nlmsg_len = NLMSG_LENGTH(sizeof(RtGenMsg))
    req.hdr.nlmsg_type = ntype
    req.hdr.nlmsg_flags = nflags
    req.hdr.nlmsg_seq = seqno
    req.hdr.nlmsg_pid = cast[uint32](pid)
    req.msg.rtgen_family = byte(AF_PACKET)
    iov.iov_base = cast[pointer](addr req)
    iov.iov_len = cast[csize](req.hdr.nlmsg_len)
    rmsg.msg_iov = addr iov
    rmsg.msg_iovlen = 1
    rmsg.msg_name = cast[pointer](addr address)
    rmsg.msg_namelen = Socklen(sizeof(SockAddr_nl))
    let res = posix.sendmsg(fd, addr rmsg, 0)
    if res == iov.iov_len:
      result = true

  proc readNetlinkMessage(fd: SocketHandle, data: var seq[byte]): bool =
    var
      rmsg: Tmsghdr
      iov: IOVec
      address: SockAddr_nl
    data.setLen(IFLIST_REPLY_BUFFER)
    iov.iov_base = cast[pointer](addr data[0])
    iov.iov_len = IFLIST_REPLY_BUFFER
    rmsg.msg_iov = addr iov
    rmsg.msg_iovlen = 1
    rmsg.msg_name = cast[pointer](addr address)
    rmsg.msg_namelen = SockLen(sizeof(SockAddr_nl))
    var length = posix.recvmsg(fd, addr rmsg, 0)
    if length >= 0:
      data.setLen(length)
      result = true
    else:
      data.setLen(0)

  proc processLink(msg: ptr NlMsgHeader): NetworkInterface =
    var iface: ptr IfInfoMessage
    var attr: ptr RtAttr
    var length: int

    iface = cast[ptr IfInfoMessage](NLMSG_DATA(msg))
    length = int(msg.nlmsg_len) - int(NLMSG_LENGTH(sizeof(IfInfoMessage)))

    attr = IFLA_RTA(cast[ptr byte](iface))
    result.ifType = toInterfaceType(iface.ifi_type)
    result.ifIndex = iface.ifi_index
    result.flags = cast[uint64](iface.ifi_flags)

    while RTA_OK(attr, length):
      if attr.rta_type == IFLA_IFNAME:
        var p = cast[cstring](RTA_DATA(attr))
        result.name = $p
      elif attr.rta_type == IFLA_ADDRESS:
        var p = cast[ptr byte](RTA_DATA(attr))
        var plen = min(int(RTA_PAYLOAD(uint(attr.rta_len))), len(result.mac))
        copyMem(addr result.mac[0], p, plen)
        result.maclen = plen
      elif attr.rta_type == IFLA_MTU:
        var p = cast[ptr uint32](RTA_DATA(attr))
        result.mtu = cast[int](p[])
      elif attr.rta_type == IFLA_OPERSTATE:
        var p = cast[ptr byte](RTA_DATA(attr))
        result.state = toInterfaceState(cast[cint](p[]), iface.ifi_flags)
      attr = RTA_NEXT(attr, length)

  proc getAddress(f: int, p: pointer): TransportAddress {.inline.} =
    if f == posix.AF_INET:
      result = TransportAddress(family: AddressFamily.IPv4)
      copyMem(addr result.address_v4[0], p, len(result.address_v4))
    elif f == posix.AF_INET6:
      result = TransportAddress(family: AddressFamily.IPv6)
      copyMem(addr result.address_v6[0], p, len(result.address_v6))

  proc processAddress(msg: ptr NlMsgHeader): NetworkInterface =
    var iaddr: ptr IfAddrMessage
    var attr: ptr RtAttr
    var length: int

    iaddr = cast[ptr IfAddrMessage](NLMSG_DATA(msg))
    length = int(msg.nlmsg_len) - int(NLMSG_LENGTH(sizeof(IfAddrMessage)))

    attr = IFA_RTA(cast[ptr byte](iaddr))

    let family = cast[int](iaddr.ifa_family)
    result.ifIndex = cast[int](iaddr.ifa_index)

    var address, local: TransportAddress

    while RTA_OK(attr, length):
      if attr.rta_type == IFA_LOCAL:
        local = getAddress(family, cast[pointer](RTA_DATA(attr)))
      elif attr.rta_type == IFA_ADDRESS:
        address = getAddress(family, cast[pointer](RTA_DATA(attr)))
      attr = RTA_NEXT(attr, length)

    if local.family != AddressFamily.None:
      address = local
    if len(result.addresses) == 0:
      result.addresses = newSeq[InterfaceAddress]()
    let prefixLength = cast[int](iaddr.ifa_prefixlen)
    result.addresses.add(InterfaceAddress(ifaddr: address,
                                          prefix: prefixLength))

  proc getLinks(netfd: SocketHandle, pid: Pid): seq[NetworkInterface] =
    if not sendNetlinkMessage(netfd, pid, 1, RTM_GETLINK,
                              NLM_F_REQUEST or NLM_F_DUMP):
      return
    var data = newSeq[byte]()
    result = newSeq[NetworkInterface]()
    while true:
      if not readNetlinkMessage(netfd, data):
        break
      var length = len(data)
      if length == 0:
        break
      var msg = cast[ptr NlMsgHeader](addr data[0])
      var endflag = false
      while NLMSG_OK(msg, length):
        if msg.nlmsg_type == NLMSG_DONE:
          endflag = true
          break
        elif msg.nlmsg_type == NLMSG_ERROR:
          endflag = true
          break
        else:
          var iface = processLink(msg)
          result.add(iface)
        msg = NLMSG_NEXT(msg, length)
      if endflag == true:
        break

  proc getAddresses(netfd: SocketHandle, pid: Pid,
                    ifaces: var seq[NetworkInterface]) =
    if not sendNetlinkMessage(netfd, pid, 2, RTM_GETADDR,
                              NLM_F_REQUEST or NLM_F_DUMP):
      return
    var data = newSeq[byte]()
    while true:
      if not readNetlinkMessage(netfd, data):
        break
      var length = len(data)
      if length == 0:
        break
      var msg = cast[ptr NlMsgHeader](addr data[0])
      var endflag = false
      while NLMSG_OK(msg, length):
        if msg.nlmsg_type == NLMSG_DONE:
          endflag = true
          break
        elif msg.nlmsg_type == NLMSG_ERROR:
          endflag = true
          break
        else:
          var iface = processAddress(msg)
          for i in 0..<len(ifaces):
            if ifaces[i].ifIndex == iface.ifIndex:
              for item in iface.addresses:
                ifaces[i].addresses.add(item)
        msg = NLMSG_NEXT(msg, length)
      if endflag == true:
        break

  proc getInterfaces*(): seq[NetworkInterface] =
    ## Return list of available interfaces.
    var pid = posix.getpid()
    var sock = createNetlinkSocket(pid)
    if sock == InvalidSocketHandle:
      return
    result = getLinks(sock, pid)
    getAddresses(sock, pid, result)
    sort(result, cmp)
    discard posix.close(sock)

elif defined(macosx) or defined(bsd):
  import posix

  const
    AF_LINK = 18
    IFF_UP = 0x01
    IFF_POINTOPOINT = 0x10
    IFF_RUNNING = 0x40

  type
    IfAddrs {.importc: "struct ifaddrs", header: "<ifaddrs.h>",
              pure, final.} = object
      ifa_next {.importc: "ifa_next".}: ptr IfAddrs
      ifa_name {.importc: "ifa_name".}: ptr cchar
      ifa_flags {.importc: "ifa_flags".}: cuint
      ifa_addr {.importc: "ifa_addr".}: ptr SockAddr
      ifa_netmask {.importc: "ifa_netmask".}: ptr SockAddr
      ifa_dstaddr {.importc: "ifa_dstaddr".}: ptr SockAddr
      ifa_data {.importc: "ifa_data".}: pointer

    PIfAddrs = ptr IfAddrs

    IfData {.importc: "struct if_data", header: "<net/if.h>",
             pure, final.} = object
      ifi_type {.importc: "ifi_type".}: byte
      ifi_typelen {.importc: "ifi_typelen".}: byte
      ifi_physical {.importc: "ifi_physical".}: byte
      ifi_addrlen {.importc: "ifi_addrlen".}: byte
      ifi_hdrlen {.importc: "ifi_hdrlen".}: byte
      ifi_recvquota {.importc: "ifi_recvquota".}: byte
      ifi_xmitquota {.importc: "ifi_xmitquota".}: byte
      ifi_unused1 {.importc: "ifi_unused1".}: byte
      ifi_mtu {.importc: "ifi_mtu".}: uint32
      ifi_metric {.importc: "ifi_metric".}: uint32
      ifi_baudrate {.importc: "ifi_baudrate".}: uint32
      ifi_ipackets {.importc: "ifi_ipackets".}: uint32
      ifi_ierrors {.importc: "ifi_ierrors".}: uint32
      ifi_opackets {.importc: "ifi_opackets".}: uint32
      ifi_oerrors {.importc: "ifi_oerrors".}: uint32
      ifi_collisions {.importc: "ifi_collisions".}: uint32
      ifi_ibytes {.importc: "ifi_ibytes".}: uint32
      ifi_obytes {.importc: "ifi_obytes".}: uint32
      ifi_imcasts {.importc: "ifi_imcasts".}: uint32
      ifi_omcasts {.importc: "ifi_omcasts".}: uint32
      ifi_iqdrops {.importc: "ifi_iqdrops".}: uint32
      ifi_noproto {.importc: "ifi_noproto".}: uint32
      ifi_recvtiming {.importc: "ifi_recvtiming".}: uint32
      ifi_xmittiming {.importc: "ifi_xmittiming".}: uint32
      ifi_lastchange {.importc: "ifi_lastchange".}: Timeval
      ifi_unused2 {.importc: "ifi_unused2".}: uint32
      ifi_hwassist {.importc: "ifi_hwassist".}: uint32
      ifi_reserved1 {.importc: "ifi_reserved1".}: uint32
      ifi_reserved2 {.importc: "ifi_reserved2".}: uint32

    SockAddr_dl = object
      sdl_len: byte
      sdl_family: byte
      sdl_index: uint16
      sdl_type: byte
      sdl_nlen: byte
      sdl_alen: byte
      sdl_slen: byte
      sdl_data: array[12, byte]

  proc getIfAddrs(ifap: ptr PIfAddrs): cint {.importc: "getifaddrs",
       header: """#include <sys/types.h>
                  #include <sys/socket.h>
                  #include <ifaddrs.h>""".}
  proc freeIfAddrs(ifap: ptr IfAddrs) {.importc: "freeifaddrs",
       header: """#include <sys/types.h>
                  #include <sys/socket.h>
                  #include <ifaddrs.h>""".}

  proc toInterfaceType(f: byte): InterfaceType {.inline.} =
    var ft = cast[int](f)
    if (ft >= 1 and ft <= 196) or (ft == 237) or (ft == 243) or (ft == 244):
      result = cast[InterfaceType](ft)
    else:
      result = IfOther

  proc toInterfaceState(f: cuint): InterfaceState {.inline.} =
    if (f and IFF_RUNNING) != 0 and (f and IFF_UP) != 0:
      result = StatusUp
    else:
      result = StatusDown

  proc netmaskToPrefix(address: TransportAddress): int =
    var lastbyte: byte
    if address.family == AddressFamily.IPv4:
      for i in 0..<len(address.address_v4):
        if address.address_v4[i] == 0xFF'u8:
          result += 8
        else:
          lastbyte = address.address_v4[i]
          break
    elif address.family == AddressFamily.IPv6:
      for i in 0..<len(address.address_v6):
        if address.address_v6[i] == 0xFF'u8:
          result += 8
        else:
          lastbyte = address.address_v6[i]
          break
    while lastbyte > 0'u8:
      lastbyte = lastbyte shl 1
      result += 1

  proc getInterfaces*(): seq[NetworkInterface] =
    ## Return list of available interfaces.
    var ifap: ptr IfAddrs
    let res = getIfAddrs(addr ifap)
    if res == 0:
      result = newSeq[NetworkInterface]()
      while not isNil(ifap):
        var iface: NetworkInterface
        var ifaddress: InterfaceAddress

        iface.name = $ifap.ifa_name
        iface.flags = cast[uint64](ifap.ifa_flags)
        var i = 0
        while i < len(result):
          if result[i].name == iface.name:
            break
          inc(i)
        if i == len(result):
          result.add(iface)

        if not isNil(ifap.ifa_addr):
          let family = cast[int](ifap.ifa_addr.sa_family)
          if family == AF_LINK:
            var data = cast[ptr IfData](ifap.ifa_data)
            var link = cast[ptr SockAddr_dl](ifap.ifa_addr)
            result[i].ifIndex = cast[int](link.sdl_index)
            let nlen = cast[int](link.sdl_nlen)
            if nlen < len(link.sdl_data):
              let minsize = min(cast[int](link.sdl_alen), len(result[i].mac))
              copyMem(addr result[i].mac[0], addr link.sdl_data[nlen], minsize)
            result[i].maclen = cast[int](link.sdl_alen)
            result[i].ifType = toInterfaceType(data.ifi_type)
            result[i].state = toInterfaceState(ifap.ifa_flags)
            result[i].mtu = cast[int](data.ifi_mtu)
          elif family == posix.AF_INET:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_addr),
                      Socklen(sizeof(SockAddr_in)), ifaddress.ifaddr)
          elif family == posix.AF_INET6:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_addr),
                      Socklen(sizeof(SockAddr_in6)), ifaddress.ifaddr)
        if not isNil(ifap.ifa_netmask):
          var na: TransportAddress
          var slen: Socklen
          var family = cast[cint](ifap.ifa_netmask.sa_family)
          if family == posix.AF_INET:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_netmask),
                      Socklen(sizeof(SockAddr_in)), na)
          elif family == posix.AF_INET6:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_netmask),
                      Socklen(sizeof(SockAddr_in6)), na)
          ifaddress.prefix = netmaskToPrefix(na)

        if ifaddress.ifaddr.family != AddressFamily.None:
          if len(result[i].addresses) == 0:
            result[i].addresses = newSeq[InterfaceAddress]()
          result[i].addresses.add(ifaddress)
        ifap = ifap.ifa_next

      sort(result, cmp)
      freeIfAddrs(ifap)

elif defined(windows):
  import winlean

  const
    IfOperStatusUp = cint(1)
    IfOperStatusDown = cint(2)
    IfOperStatusTesting = cint(3)
    IfOperStatusUnknown = cint(4)
    IfOperStatusDormant = cint(5)
    IfOperStatusNotPresent = cint(6)
    IfOperStatusLowerLayerDown = cint(7)

    IpPrefixOriginOther = cint(0)
    IpPrefixOriginManual = cint(1)
    IpPrefixOriginWellKnown = cint(2)
    IpPrefixOriginDhcp = cint(3)
    IpPrefixOriginRouterAdvertisement = cint(4)
    IpPrefixOriginUnchanged = cint(1) shl 4

    IpSuffixOriginOther = cint(0)
    IpSuffixOriginManual = cint(1)
    IpSuffixOriginWellKnown = cint(2)
    IpSuffixOriginDhcp = cint(3)
    IpSuffixOriginLinkLayerAddress = cint(4)
    IpSuffixOriginRandom = cint(5)
    IpSuffixOriginUnchanged = cint(1) shl 4

    IpDadStateInvalid = cint(0)
    IpDadStateTentative = cint(1)
    IpDadStateDuplicate = cint(2)
    IpDadStateDeprecated = cint(3)
    IpDadStatePreferred = cint(4)

    WorkBufferSize = 16384'u32
    MaxTries = 3

    AF_UNSPEC = 0x00'u32

    GAA_FLAG_INCLUDE_PREFIX = 0x0010'u32

    CP_UTF8 = 65001'u32

    ERROR_BUFFER_OVERFLOW* = 111'u32
    ERROR_SUCCESS* = 0'u32

  type
    WCHAR = distinct uint16

    SocketAddress = object
      lpSockaddr: ptr SockAddr
      iSockaddrLength: cint

    IpAdapterUnicastAddressXpLh = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterUnicastAddressXpLh
      address: SocketAddress
      prefixOrigin: cint
      suffixOrigin: cint
      dadState: cint
      validLifetime: uint32
      preferredLifetime: uint32
      leaseLifetime: uint32
      onLinkPrefixLength: byte # This field is available only from Vista

    IpAdapterAnycastAddressXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterAnycastAddressXp
      address: SocketAddress

    IpAdapterMulticastAddressXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterMulticastAddressXp
      address: SocketAddress

    IpAdapterDnsServerAddressXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterDnsServerAddressXp
      address: SocketAddress

    IpAdapterPrefixXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterPrefixXp
      address: SocketAddress
      prefixLength: uint32

    IpAdapterAddressesXp = object
      length: uint32
      ifIndex: uint32
      next: ptr IpAdapterAddressesXp
      adapterName: cstring
      unicastAddress: ptr IpAdapterUnicastAddressXpLh
      anycastAddress: ptr IpAdapterAnycastAddressXp
      multicastAddress: ptr IpAdapterMulticastAddressXp
      dnsServerAddress: ptr IpAdapterDnsServerAddressXp
      dnsSuffix: ptr WCHAR
      description: ptr WCHAR
      friendlyName: ptr WCHAR
      physicalAddress: array[MaxAdapterAddressLength, byte]
      physicalAddressLength: uint32
      flags: uint32
      mtu: uint32
      ifType: uint32
      operStatus: cint
      ipv6IfIndex: uint32
      zoneIndices: array[16, uint32]
      firstPrefix: ptr IpAdapterPrefixXp

  proc toInterfaceType(ft: uint32): InterfaceType {.inline.} =
    if (ft >= 1'u32 and ft <= 196'u32) or
       (ft == 237) or (ft == 243) or (ft == 244) or (ft == 259) or (ft == 281):
      result = cast[InterfaceType](ft)
    else:
      result = IfOther

  proc toInterfaceState(it: cint): InterfaceState  {.inline.} =
    if it >= 1 and it <= 7:
      result = cast[InterfaceState](it)
    else:
      result = StatusUnknown

  proc GetAdaptersAddresses(family: uint32, flags: uint32, reserved: pointer,
                            addresses: ptr IpAdapterAddressesXp,
                            sizeptr: ptr uint32): uint32 {.
       stdcall, dynlib: "iphlpapi", importc: "GetAdaptersAddresses".}

  proc WideCharToMultiByte(CodePage: uint32, dwFlags: uint32,
                           lpWideCharStr: ptr WCHAR, cchWideChar: cint,
                           lpMultiByteStr: ptr char, cbMultiByte: cint,
                           lpDefaultChar: ptr char,
                           lpUsedDefaultChar: ptr uint32): cint
       {.stdcall, dynlib: "kernel32.dll", importc: "WideCharToMultiByte".}

  proc `$`(bstr: ptr WCHAR): string =
    var buffer: char
    var count = WideCharToMultiByte(CP_UTF8, 0, bstr, -1, addr(buffer), 0,
                                    nil, nil)
    if count > 0:
      result = newString(count + 8)
      let res = WideCharToMultiByte(CP_UTF8, 0, bstr, -1, addr(result[0]),
                                    count, nil, nil)
      if res > 0:
        result.setLen(res - 1)
      else:
        result.setLen(0)

  proc isVista(): bool =
    var ver: OSVERSIONINFO
    ver.dwOSVersionInfoSize = DWORD(sizeof(ver))
    let res = getVersionExW(addr(ver))
    if res == 0:
      result = false
    else:
      result = (ver.dwMajorVersion >= 6)

  proc toIPv6(a: TransportAddress): TransportAddress =
    ## IPv4-mapped addresses are formed by:
    ## <80 bits of zeros> + <16 bits of ones> + <32-bit IPv4 address>.
    if a.family == AddressFamily.IPv4:
      result = TransportAddress(family: AddressFamily.IPv6)
      result.address_v6[10] = 0xFF'u8
      result.address_v6[11] = 0xFF'u8
      copyMem(addr result.address_v6[12], unsafeAddr a.address_v4[0], 4)
    elif a.family == AddressFamily.IPv6:
      result = a

  proc ipMatchPrefix(number, prefix: TransportAddress, nbits: int): bool =
    var num6, prefix6: TransportAddress
    if number.family == AddressFamily.IPv4:
      num6 = toIPv6(number)
    else:
      num6 = number
    if prefix.family == AddressFamily.IPv4:
      prefix6 = toIPv6(number)
    else:
      prefix6 = prefix
    var bytesCount = nbits div 8
    var bitsCount = nbits mod 8
    for i in 0..<bytesCount:
      if num6.address_v6[i] != prefix6.address_v6[i]:
        return false
    if bitsCount != 0:
      var mask = cast[byte](0xFF'u8 shl (8 - bitsCount))
      let i = bytesCount
      if (num6.address_v6[i] and mask) != (prefix6.address_v6[i] and mask):
        return false
    result = true

  proc processAddress(ifitem: ptr IpAdapterAddressesXp,
                      ifunic: ptr IpAdapterUnicastAddressXpLh,
                      vista: bool): InterfaceAddress =
    var netfamily = ifunic.address.lpSockaddr.sa_family
    fromSAddr(cast[ptr Sockaddr_storage](ifunic.address.lpSockaddr),
              SockLen(ifunic.address.iSockaddrLength), result.ifaddr)
    if not vista:
      var prefix = ifitem.firstPrefix
      var prefixLength = -1
      while not isNil(prefix):
        var pa: TransportAddress
        var prefamily = prefix.address.lpSockaddr.sa_family
        fromSAddr(cast[ptr Sockaddr_storage](prefix.address.lpSockaddr),
                  SockLen(prefix.address.iSockaddrLength), pa)
        if netfamily == prefamily:
          if ipMatchPrefix(result.ifaddr, pa, cast[int](prefix.prefixLength)):
            prefixLength = max(prefixLength, cast[int](prefix.prefixLength))
        prefix = prefix.next
      if prefixLength >= 0:
        result.prefix = prefixLength
    else:
      let prefixLength = cast[int](ifunic.onLinkPrefixLength)
      if prefixLength >= 0:
        result.prefix = prefixLength

  proc getInterfaces*(): seq[NetworkInterface] =
    ## Return list of network interfaces.
    result = newSeq[NetworkInterface]()
    var size = WorkBufferSize
    var tries = 0
    var buffer: seq[byte]
    var res: uint32
    var vista = isVista()

    while true:
      buffer = newSeq[byte](size)
      var addresses = cast[ptr IpAdapterAddressesXp](addr buffer[0])
      res = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, nil,
                                 addresses, addr size)
      if res == ERROR_SUCCESS:
        buffer.setLen(size)
        break
      elif res == ERROR_BUFFER_OVERFLOW:
        discard
      else:
        break
      inc(tries)
      if tries >= MaxTries:
        break

    if res == ERROR_SUCCESS:
      var slider = cast[ptr IpAdapterAddressesXp](addr buffer[0])
      while not isNil(slider):
        var iface = NetworkInterface(
          ifIndex: cast[int](slider.ifIndex),
          ifType: toInterfaceType(slider.ifType),
          state: toInterfaceState(slider.operStatus),
          name: $slider.adapterName,
          desc: $slider.description,
          mtu: cast[int](slider.mtu),
          maclen: cast[int](slider.physicalAddressLength),
          flags: cast[uint64](slider.flags)
        )
        copyMem(addr iface.mac[0], addr slider.physicalAddress[0],
                len(iface.mac))
        var unicast = slider.unicastAddress
        while not isNil(unicast):
          var ifaddr = processAddress(slider, unicast, vista)
          iface.addresses.add(ifaddr)
          unicast = unicast.next
        result.add(iface)
        slider = slider.next

      sort(result, cmp)

else:
  {.fatal: "Sorry, your OS is currently not supported!".}

when isMainModule:
  var a = getInterfaces()
  for item in a:
    echo $item
