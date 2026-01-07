import pkg/questionable
import pkg/stew/byteutils
import pkg/libp2p
import pkg/codexdht/discv5/node as dn
import pkg/codexdht/discv5/routing_table as rt
import ../utils/json
import ../manifest
import ../units

export json

type
  RestContent* = object
    cid* {.serialize.}: Cid
    manifest* {.serialize.}: Manifest

  RestContentList* = object
    content* {.serialize.}: seq[RestContent]

  RestNode* = object
    nodeId* {.serialize.}: RestNodeId
    peerId* {.serialize.}: PeerId
    record* {.serialize.}: SignedPeerRecord
    address* {.serialize.}: Option[dn.Address]
    seen* {.serialize.}: bool

  RestRoutingTable* = object
    localNode* {.serialize.}: RestNode
    nodes* {.serialize.}: seq[RestNode]

  RestPeerRecord* = object
    peerId* {.serialize.}: PeerId
    seqNo* {.serialize.}: uint64
    addresses* {.serialize.}: seq[AddressInfo]

  RestNodeId* = object
    id*: NodeId

  RestRepoStore* = object
    totalBlocks* {.serialize.}: Natural
    quotaMaxBytes* {.serialize.}: NBytes
    quotaUsedBytes* {.serialize.}: NBytes
    quotaReservedBytes* {.serialize.}: NBytes

proc init*(_: type RestContentList, content: seq[RestContent]): RestContentList =
  RestContentList(content: content)

proc init*(_: type RestContent, cid: Cid, manifest: Manifest): RestContent =
  RestContent(cid: cid, manifest: manifest)

proc init*(_: type RestNode, node: dn.Node): RestNode =
  RestNode(
    nodeId: RestNodeId.init(node.id),
    peerId: node.record.data.peerId,
    record: node.record,
    address: node.address,
    seen: node.seen > 0.5,
  )

proc init*(_: type RestRoutingTable, routingTable: rt.RoutingTable): RestRoutingTable =
  var nodes: seq[RestNode] = @[]
  for bucket in routingTable.buckets:
    for node in bucket.nodes:
      nodes.add(RestNode.init(node))

  RestRoutingTable(localNode: RestNode.init(routingTable.localNode), nodes: nodes)

proc init*(_: type RestPeerRecord, peerRecord: PeerRecord): RestPeerRecord =
  RestPeerRecord(
    peerId: peerRecord.peerId, seqNo: peerRecord.seqNo, addresses: peerRecord.addresses
  )

proc init*(_: type RestNodeId, id: NodeId): RestNodeId =
  RestNodeId(id: id)

proc `%`*(obj: RestNodeId): JsonNode =
  % $obj.id
