import pkg/chronos
import pkg/asynctest
import pkg/ipfs/p2p/switch
import pkg/ipfs/bitswap/messages
import pkg/ipfs/bitswap/protocol

suite "bitswap protocol":

  let address = MultiAddress.init("/ip4/127.0.0.1/tcp/45344").get()
  let message = Message.send(@[1'u8, 2'u8, 3'u8])

  var peer1, peer2: Switch
  var bitswap: BitswapProtocol

  setup:
    peer1 = Switch.create()
    peer2 = Switch.create()
    bitswap = BitswapProtocol.new()
    peer1.peerInfo.addrs.add(address)
    peer1.mount(bitswap)
    discard await peer1.start()
    discard await peer2.start()

  teardown:
    await peer1.stop()
    await peer2.stop()

  test "opens a stream to another peer":
    let stream = await peer2.dial(peer1.peerInfo, BitswapProtocol)
    await stream.close()

  test "accepts a stream from another peer":
    let outgoing = await peer2.dial(peer1.peerInfo, BitswapProtocol)
    let incoming = await bitswap.accept()
    await outgoing.close()
    await incoming.close()

  test "writes messages to a stream":
    let stream = await peer2.dial(peer1.peerInfo, BitswapProtocol)
    await stream.write(message)
    await stream.close()

  test "reads messages from incoming stream":
    let outgoing = await peer2.dial(peer1.peerInfo, BitswapProtocol)
    let incoming = await bitswap.accept()
    await outgoing.write(message)
    check (await incoming.read()) == message
    await outgoing.close()
    await incoming.close()

  test "reads messages from outgoing stream":
    let outgoing = await peer2.dial(peer1.peerInfo, BitswapProtocol)
    let incoming = await bitswap.accept()
    await incoming.write(message)
    check (await outgoing.read()) == message
    await outgoing.close()
    await incoming.close()
