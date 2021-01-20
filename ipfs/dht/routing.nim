import pkg/libp2p

type
  RoutingTable* = object
    peers: seq[PeerInfo]

proc add*(table: var RoutingTable, peer: PeerInfo) =
  table.peers.add(peer)

proc closest*(table: RoutingTable, id: Cid): seq[PeerInfo] =
  table.peers
