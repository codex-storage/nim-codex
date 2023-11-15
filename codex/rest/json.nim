import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/libp2p
import pkg/codexdht/discv5/node as dn
import pkg/codexdht/discv5/routing_table as rt
import ../sales
import ../purchasing
import ../utils/json
import ../units
import ../manifest

export json

type
  StorageRequestParams* = object
    duration* {.serialize.}: UInt256
    proofProbability* {.serialize.}: UInt256
    reward* {.serialize.}: UInt256
    collateral* {.serialize.}: UInt256
    expiry* {.serialize.}: ?UInt256
    nodes* {.serialize.}: ?uint
    tolerance* {.serialize.}: ?uint

  RestPurchase* = object
    requestId* {.serialize.}: RequestId
    request* {.serialize.}: ?StorageRequest
    state* {.serialize.}: string
    error* {.serialize.}: ?string

  RestAvailability* = object
    size* {.serialize.}: UInt256
    duration* {.serialize.}: UInt256
    minPrice* {.serialize.}: UInt256
    maxCollateral* {.serialize.}: UInt256

  RestContent* = object
    cid* {.serialize.}: Cid
    manifest* {.serialize.}: Manifest

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

proc init*(_: type RestContent, cid: Cid, manifest: Manifest): RestContent =
  RestContent(
    cid: cid,
    manifest: manifest
  )

proc init*(_: type RestNode, node: dn.Node): RestNode =
  RestNode(
    nodeId: RestNodeId.init(node.id),
    peerId: node.record.data.peerId,
    record: node.record,
    address: node.address,
    seen: node.seen
  )

proc init*(_: type RestRoutingTable, routingTable: rt.RoutingTable): RestRoutingTable =
  var nodes: seq[RestNode] = @[]
  for bucket in routingTable.buckets:
    for node in bucket.nodes:
      nodes.add(RestNode.init(node))

  RestRoutingTable(
    localNode: RestNode.init(routingTable.localNode),
    nodes: nodes
  )

proc init*(_: type RestPeerRecord, peerRecord: PeerRecord): RestPeerRecord =
  RestPeerRecord(
    peerId: peerRecord.peerId,
    seqNo: peerRecord.seqNo,
    addresses: peerRecord.addresses
  )

proc init*(_: type RestNodeId, id: NodeId): RestNodeId =
  RestNodeId(
    id: id
  )

func `%`*(obj: StorageRequest | Slot): JsonNode =
  let jsonObj = newJObject()
  for k, v in obj.fieldPairs: jsonObj[k] = %v
  jsonObj["id"] = %(obj.id)

  return jsonObj

func `%`*(obj: Cid): JsonNode =
  % $obj

func `%`*(obj: PeerId): JsonNode =
  % $obj

func `%`*(obj: RestNodeId): JsonNode =
  % $obj.id

func `%`*(obj: SignedPeerRecord): JsonNode =
  % $obj

func `%`*(obj: dn.Address): JsonNode =
  % $obj

func `%`*(obj: AddressInfo): JsonNode =
  % $obj.address

func `%`*(obj: MultiAddress): JsonNode =
  % $obj
