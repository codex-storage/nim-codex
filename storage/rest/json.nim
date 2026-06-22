import pkg/questionable
import pkg/libp2p
import pkg/codexdht/discv5/node as dn
import pkg/codexdht/discv5/routing_table as rt
import ../node
import ../conf
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

  VersionInfo* = object
    version* {.serialize.}: string
    revision* {.serialize.}: string

  DebugInfo* = object
    id* {.serialize.}: PeerId
    addrs* {.serialize.}: seq[MultiAddress]
    repo* {.serialize.}: string
    spr* {.serialize.}: Option[SignedPeerRecord]
    providerRecord* {.serialize.}: Option[SignedPeerRecord]
    announceAddresses* {.serialize.}: seq[MultiAddress]
    table* {.serialize.}: RestRoutingTable
    storage* {.serialize.}: VersionInfo

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

proc init*(_: type DebugInfo, node: StorageNodeRef): DebugInfo =
  DebugInfo(
    id: node.switch.peerInfo.peerId,
    addrs: node.switch.peerInfo.addrs,
    spr: node.discovery.dhtRecord,
    providerRecord: node.discovery.providerRecord,
    announceAddresses: node.discovery.announceAddrs,
    table: RestRoutingTable.init(node.discovery.protocol.routingTable),
    storage: VersionInfo(version: $storageVersion, revision: $storageRevision),
  )
