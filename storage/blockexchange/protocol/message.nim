# Protocol of data exchange between Logos Storage nodes
# and Protobuf encoder/decoder for these messages.
#
# Eventually all this code should be auto-generated from message.proto.
import std/sugar

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p/cid

import pkg/questionable

import ../../merkletree
import ../../blocktype

type
  WantType* = enum
    WantHave = 0 # Presence query - the only type used with batch transfer protocol

  WantListEntry* = object
    address*: BlockAddress
    priority*: int32 # The priority (normalized). default to 1
    cancel*: bool # Whether this revokes an entry
    wantType*: WantType # Defaults to WantHave (only type supported)
    sendDontHave*: bool # Note: defaults to false
    rangeCount*: uint64
      # For range queries: number of sequential blocks starting from address.index (0 = single block)
    downloadId*: uint64 # Unique download ID for request/response correlation

  WantList* = object
    entries*: seq[WantListEntry] # A list of wantList entries
    full*: bool # Whether this is the full wantList. default to false

  BlockDelivery* = object
    blk*: Block
    address*: BlockAddress
    proof*: ?StorageMerkleProof

  BlockPresenceType* = enum
    DontHave = 0
    HaveRange = 1
    Complete = 2

  BlockPresence* = object
    address*: BlockAddress
    kind*: BlockPresenceType
    ranges*: seq[tuple[start: uint64, count: uint64]]
    downloadId*: uint64 # echoed for request/response correlation

  Message* = object
    wantList*: WantList
    blockPresences*: seq[BlockPresence]

#
# Encoding Message into seq[byte] in Protobuf format
#

proc write*(pb: var ProtoBuffer, field: int, value: BlockAddress) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.treeCid.data.buffer)
  ipb.write(2, value.index.uint64)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: WantListEntry) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.write(2, value.priority.uint64)
  ipb.write(3, value.cancel.uint)
  ipb.write(4, value.wantType.uint)
  ipb.write(5, value.sendDontHave.uint)
  ipb.write(6, value.rangeCount)
  ipb.write(7, value.downloadId)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: WantList) =
  var ipb = initProtoBuffer()
  for v in value.entries:
    ipb.write(1, v)
  ipb.write(2, value.full.uint)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: BlockPresence) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.write(2, value.kind.uint)
  # Encode ranges if present
  for (start, count) in value.ranges:
    var rangePb = initProtoBuffer()
    rangePb.write(1, start)
    rangePb.write(2, count)
    rangePb.finish()
    ipb.write(3, rangePb)
  ipb.write(4, value.downloadId)
  ipb.finish()
  pb.write(field, ipb)

proc protobufEncode*(value: Message): seq[byte] =
  var ipb = initProtoBuffer()
  ipb.write(1, value.wantList)
  for v in value.blockPresences:
    ipb.write(4, v)
  ipb.finish()
  ipb.buffer

#
# Decoding Message from seq[byte] in Protobuf format
#
proc decode*(_: type BlockAddress, pb: ProtoBuffer): ProtoResult[BlockAddress] =
  var
    value: BlockAddress
    field: uint64
    cidBuf = newSeq[byte]()

  if ?pb.getField(1, cidBuf):
    value.treeCid = ?Cid.init(cidBuf).mapErr(x => ProtoError.IncorrectBlob)
  if ?pb.getField(2, field):
    value.index = field

  ok(value)

proc decode*(_: type WantListEntry, pb: ProtoBuffer): ProtoResult[WantListEntry] =
  var
    value = WantListEntry()
    field: uint64
    ipb: ProtoBuffer
  if ?pb.getField(1, ipb):
    value.address = ?BlockAddress.decode(ipb)
  if ?pb.getField(2, field):
    value.priority = int32(field)
  if ?pb.getField(3, field):
    value.cancel = bool(field)
  if ?pb.getField(4, field):
    value.wantType = WantType(field)
  if ?pb.getField(5, field):
    value.sendDontHave = bool(field)
  if ?pb.getField(6, field):
    value.rangeCount = field
  if ?pb.getField(7, field):
    value.downloadId = field
  ok(value)

proc decode*(_: type WantList, pb: ProtoBuffer): ProtoResult[WantList] =
  var
    value = WantList()
    field: uint64
    sublist: seq[seq[byte]]
  if ?pb.getRepeatedField(1, sublist):
    for item in sublist:
      value.entries.add(?WantListEntry.decode(initProtoBuffer(item)))
  if ?pb.getField(2, field):
    value.full = bool(field)
  ok(value)

proc decode*(_: type BlockPresence, pb: ProtoBuffer): ProtoResult[BlockPresence] =
  var
    value = BlockPresence()
    field: uint64
    ipb: ProtoBuffer
    rangelist: seq[seq[byte]]
  if ?pb.getField(1, ipb):
    value.address = ?BlockAddress.decode(ipb)
  if ?pb.getField(2, field):
    value.kind = BlockPresenceType(field)
  if ?pb.getRepeatedField(3, rangelist):
    for item in rangelist:
      var rangePb = initProtoBuffer(item)
      var start, count: uint64
      discard ?rangePb.getField(1, start)
      discard ?rangePb.getField(2, count)
      value.ranges.add((start, count))
  if ?pb.getField(4, field):
    value.downloadId = field
  ok(value)

proc protobufDecode*(_: type Message, msg: seq[byte]): ProtoResult[Message] =
  var
    value = Message()
    pb = initProtoBuffer(msg)
    ipb: ProtoBuffer
    sublist: seq[seq[byte]]
  if ?pb.getField(1, ipb):
    value.wantList = ?WantList.decode(ipb)
  if ?pb.getRepeatedField(4, sublist):
    for item in sublist:
      value.blockPresences.add(?BlockPresence.decode(initProtoBuffer(item)))
  ok(value)
