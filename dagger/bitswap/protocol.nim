import pkg/chronos
import pkg/libp2p/switch
import pkg/libp2p/stream/connection
import pkg/libp2p/protocols/protocol
import ./stream

export stream except readLoop

const Codec = "/ipfs/bitswap/1.2.0"

type
  BitswapProtocol* = ref object of LPProtocol
    connections: AsyncQueue[BitswapStream]

proc new*(t: type BitswapProtocol): BitswapProtocol =
  let connections = newAsyncQueue[BitswapStream](1)
  proc handle(connection: Connection, proto: string) {.async.} =
    let stream = BitswapStream.new(connection)
    await connections.put(stream)
    await stream.readLoop()
  BitswapProtocol(connections: connections, codecs: @[Codec], handler: handle)

proc dial*(switch: Switch,
           peer: PeerInfo,
           t: type BitswapProtocol):
           Future[BitswapStream] {.async.} =
  let connection = await switch.dial(peer.peerId, peer.addrs, Codec)
  let stream = BitswapStream.new(connection)
  asyncSpawn stream.readLoop()
  result = stream

proc accept*(bitswap: BitswapProtocol): Future[BitswapStream] {.async.} =
  result = await bitswap.connections.get()
