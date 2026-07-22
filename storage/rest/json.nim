import std/importutils

import pkg/questionable
import pkg/libp2p
import pkg/libp2p_mix
import pkg/libp2p_mix/curve25519
import pkg/codexdht/discv5/node as dn
import pkg/codexdht/discv5/routing_table as rt
import pkg/stew/byteutils
import pkg/libp2p/protocols/connectivity/autonatv2/service
import pkg/libp2p/services/autorelayservice
import ../node
import ../nat
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

  NatDebugInfo* = object
    reachability* {.serialize.}: string
    clientMode* {.serialize.}: bool
    relayRunning* {.serialize.}: bool
    portMapping* {.serialize.}: string

  DebugInfo* = object # Peer's ID
    id* {.serialize.}: PeerId
    # peer addresses known by the libp2p switch
    addrs* {.serialize.}: seq[MultiAddress]
    # local data directory
    repo* {.serialize.}: string
    # signed peer record (URI form)
    spr* {.serialize.}: Option[SignedPeerRecord]
    # provider record (the one we announce for content we provide)
    providerRecord* {.serialize.}: Option[SignedPeerRecord]
    # addresses contained in the provider record
    announceAddresses* {.serialize.}: seq[MultiAddress]
    # UDP addresses announced in the DHT
    dhtAddresses* {.serialize.}: seq[MultiAddress]
    # libp2p public key
    libp2pPubKey* {.serialize.}: string
    # mix public key (for nodes that support mix)
    mixPubKey* {.serialize.}: Option[FieldElement]
    table* {.serialize.}: RestRoutingTable
    storage* {.serialize.}: VersionInfo
    # NAT reachability, relay and port-mapping status
    nat* {.serialize.}: NatDebugInfo
    # active peer connections
    connections* {.serialize.}: JsonNode

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

proc init*(
    _: type DebugInfo,
    node: StorageNodeRef,
    conf: StorageConf,
    autonat: Option[AutonatV2Service],
    autoRelay: Option[AutoRelayService],
    natMapper: Option[NatPortMapper],
): DebugInfo =
  let
    peerInfo = node.switch.peerInfo
    peerId = peerInfo.peerId
    libp2pPubKeyBytes = peerInfo.publicKey.getRawBytes()

  # Cause there's no canonical way to get your own key from MixProtocol
  # that I'm aware of.
  privateAccess(MixProtocol)

  DebugInfo(
    id: peerId,
    addrs: peerInfo.addrs,
    repo: $conf.dataDir,
    spr: some(node.discovery.getSpr()),
    providerRecord: node.discovery.providerRecord,
    announceAddresses: node.discovery.announceAddrs,
    dhtAddresses: node.discovery.dhtAddrs,
    table: RestRoutingTable.init(node.discovery.protocol.routingTable),
    storage: VersionInfo(version: $storageVersion, revision: $storageRevision),
    # Serialization has no error contract in nim-serde, so we need to
    # handle this here.
    libp2pPubKey:
      if libp2pPubKeyBytes.isErr:
        $libp2pPubKeyBytes.error
      else:
        byteutils.toHex(libp2pPubKeyBytes.get),
    mixPubKey:
      if node.discovery.mixProto.isNil():
        none(FieldElement)
      else:
        # It's a bug if we don't have the peer in the pool, so let it throw an exception.
        some(node.discovery.mixProto.mixNodeInfo.mixPubKey),
    nat: NatDebugInfo(
      reachability: reachabilityStr(autonat),
      clientMode: node.discovery.protocol.clientMode,
      relayRunning: autoRelay.isSome and autoRelay.get.isRunning,
      portMapping: portMappingStr(natMapper),
    ),
    connections: peerConnections(node.switch),
  )
