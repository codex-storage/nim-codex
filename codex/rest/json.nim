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

proc init*(_: type RestContent, cid: Cid, manifest: Manifest): RestContent =
  RestContent(
    cid: cid,
    manifest: manifest
  )

func `%`*(obj: StorageRequest | Slot): JsonNode =
  let jsonObj = newJObject()
  for k, v in obj.fieldPairs: jsonObj[k] = %v
  jsonObj["id"] = %(obj.id)

  return jsonObj

func `%`*(obj: Cid): JsonNode =
  % $obj

proc formatAddress(address: Option[dn.Address]): string =
  if address.isSome():
    return $address.get()
  return "<none>"

proc `%`*(node: dn.Node): JsonNode =
  let jobj = %*{
    "nodeId": $node.id,
    "peerId": $node.record.data.peerId,
    "record": $node.record,
    "address": formatAddress(node.address),
    "seen": $node.seen
  }
  return jobj

proc `%`*(routingTable: rt.RoutingTable): JsonNode =
  let jarray = newJArray()
  for bucket in routingTable.buckets:
    for node in bucket.nodes:
      jarray.add(%node)

  let jobj = %*{
    "localNode": routingTable.localNode,
    "nodes": jarray
  }
  return jobj

proc `%`*(peerRecord: PeerRecord): JsonNode =
  let jarray = newJArray()
  for maddr in peerRecord.addresses:
    jarray.add(%*{
      "address": $maddr.address
    })

  let jobj = %*{
    "peerId": $peerRecord.peerId,
    "seqNo": $peerRecord.seqNo,
    "addresses": jarray
  }
  return jobj
