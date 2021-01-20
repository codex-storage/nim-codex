import std/unittest
import pkg/libp2p
import pkg/ipfs/ipfsobject
import pkg/ipfs/dht/routing

suite "DHT routing table":

  test "finds peers closest to some content":
    let peer1 = PeerInfo(peer: PeerId(data: @[1'u8]))
    let peer2 = PeerInfo(peer: PeerId(data: @[2'u8]))
    let contentId = IpfsObject(data: @[]).cid

    var table = RoutingTable()
    table.add(peer1)
    table.add(peer2)

    check table.closest(contentId) == @[peer1, peer2]
