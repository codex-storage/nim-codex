import pkg/libp2p
import pkg/libp2p/errors

import pkg/storage/rng

proc newStandardSwitch*(
    addrs: MultiAddress | seq[MultiAddress] = newSeq[MultiAddress](),
    transportFlags: set[ServerFlags] = {},
    sendSignedPeerRecord = false,
): Switch {.raises: [LPError].} =
  var addrs =
    when addrs is MultiAddress:
      @[addrs]
    else:
      addrs
  if addrs.len == 0:
    addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").expect("invalid multiaddress")]

  SwitchBuilder
    .new()
    .withRng(Rng.instance())
    .withSignedPeerRecord(sendSignedPeerRecord)
    .withAddresses(addrs)
    .withTcpTransport(transportFlags)
    .withMplex()
    .withNoise()
    .build()
