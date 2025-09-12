const
  k* = 16 # Security parameter
  r* = 5 # Maximum path length
  t* = 6 # t.k - combined length of next hop address and delay
  L* = 3 # Path length
  alphaSize* = 32 # Group element
  betaSize* = ((r * (t + 1)) + 1) * k # (r(t+1)+1)k bytes
  gammaSize* = 16 # Output of HMAC-SHA-256, truncated to 16 bytes
  headerSize* = alphaSize + betaSize + gammaSize # Total header size
  delaySize* = 2 # Delay size
  addrSize* = (t * k) - delaySize # Address size
  packetSize* = 4608 # Total packet size (from spec)
  messageSize* = packetSize - headerSize - k # Size of the message itself
  payloadSize* = messageSize + k # Total payload size
  surbSize* = headerSize + k + addrSize
    # Size of a surb packet inside the message payload
  surbLenSize* = 1 # Size of the field storing the number of surbs
  surbIdLen* = k # Size of the identifier used when sending a message with surb
  defaultSurbs* = uint8(4) # Default number of SURBs to send
