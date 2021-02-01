import pkg/chronos
import pkg/asynctest
import pkg/ipfs/ipfsobject
import pkg/ipfs/p2p/switch
import pkg/ipfs/bitswap

suite "bitswap":

  let address = MultiAddress.init("/ip4/127.0.0.1/tcp/40981").get()
  let obj = IpfsObject(data: @[1'u8, 2'u8, 3'u8])

  var bitswap1, bitswap2: Bitswap
  var peer1, peer2: Switch

  setup:
    peer1 = Switch.create()
    peer2 = Switch.create()
    peer1.peerInfo.addrs.add(address)
    discard await peer1.start()
    discard await peer2.start()
    bitswap1 = Bitswap.start(peer1)
    bitswap2 = Bitswap.start(peer2)

  teardown:
    await peer1.stop()
    await peer2.stop()

  test "stores ipfs objects":
    bitswap1.store(obj)

  test "retrieves local objects":
    bitswap1.store(obj)
    check (await bitswap1.retrieve(obj.cid)).get() == obj

  test "signals retrieval failure":
    check (await bitswap1.retrieve(obj.cid, 100.milliseconds)).isNone

  test "retrieves objects from network":
    bitswap1.store(obj)
    await bitswap2.connect(peer1.peerInfo)
    check (await bitswap2.retrieve(obj.cid)).get() == obj
