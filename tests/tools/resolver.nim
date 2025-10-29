import ../../libp2p/nameresolving/mockresolver

export mockresolver

proc default*(T: typedesc[MockResolver]): T =
  let resolver = MockResolver.new()
  resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
  resolver.ipResponses[("localhost", true)] = @["::1"]
  resolver
