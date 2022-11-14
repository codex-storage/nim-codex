# Protocol of data exchange between Codex nodes
# and Protobuf encoder/decoder for these messages.
#
# Eventually all this code should be auto-generated from message.proto.

import pkg/libp2p/protobuf/minprotobuf


type
  WantType* = enum
    WantBlock = 0,
    WantHave = 1

  Entry* = object
    `block`*: seq[byte]     # The block cid
    priority*: int32        # The priority (normalized). default to 1
    cancel*: bool           # Whether this revokes an entry
    wantType*: WantType     # Note: defaults to enum 0, ie Block
    sendDontHave*: bool     # Note: defaults to false

  Wantlist* = object
    entries*: seq[Entry]    # A list of wantlist entries
    full*: bool             # Whether this is the full wantlist. default to false

  Block* = object
    prefix*: seq[byte]      # CID prefix (cid version, multicodec and multihash prefix (type + length)
    data*: seq[byte]

  BlockPresenceType* = enum
    Have = 0,
    DontHave = 1

  BlockPresence* = object
    cid*: seq[byte]         # The block cid
    `type`*: BlockPresenceType
    price*: seq[byte]       # Amount of assets to pay for the block (UInt256)

  AccountMessage* = object
    address*: seq[byte]     # Ethereum address to which payments should be made

  StateChannelUpdate* = object
    update*: seq[byte]      # Signed Nitro state, serialized as JSON

  Message* = object
    wantlist*: Wantlist
    payload*: seq[Block]
    blockPresences*: seq[BlockPresence]
    pendingBytes*: uint
    account*: AccountMessage
    payment*: StateChannelUpdate

#
# Encoding Message into seq[byte] in Protobuf format
#

proc write*(pb: var ProtoBuffer, field: int, value: Entry) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.`block`)
  ipb.write(2, value.priority.uint64)
  ipb.write(3, value.cancel.uint)
  ipb.write(4, value.wantType.uint)
  ipb.write(5, value.sendDontHave.uint)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: Wantlist) =
  var ipb = initProtoBuffer()
  for v in value.entries:
    ipb.write(1, v)
  ipb.write(2, value.full.uint)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: Block) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.prefix)
  ipb.write(2, value.data)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: BlockPresence) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.cid)
  ipb.write(2, value.`type`.uint)
  ipb.write(3, value.price)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: AccountMessage) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: StateChannelUpdate) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.update)
  ipb.finish()
  pb.write(field, ipb)

proc ProtobufEncode*(value: Message): seq[byte] =
  var ipb = initProtoBuffer()
  ipb.write(1, value.wantlist)
  for v in value.payload:
    ipb.write(3, v)
  for v in value.blockPresences:
    ipb.write(4, v)
  ipb.write(5, value.pendingBytes)
  ipb.write(6, value.account)
  ipb.write(7, value.payment)
  ipb.finish()
  ipb.buffer


#
# Decoding Message from seq[byte] in Protobuf format
#

proc decode*(_: type Entry, pb: ProtoBuffer): ProtoResult[Entry] =
  var
    value = Entry()
    field: uint64
  discard ? pb.getField(1, value.`block`)
  if ? pb.getField(2, field):
    value.priority = int32(field)
  if ? pb.getField(3, field):
    value.cancel = bool(field)
  if ? pb.getField(4, field):
    value.wantType = WantType(field)
  if ? pb.getField(5, field):
    value.sendDontHave = bool(field)
  ok(value)

proc decode*(_: type Wantlist, pb: ProtoBuffer): ProtoResult[Wantlist] =
  var
    value = Wantlist()
    field: uint64
    sublist: seq[seq[byte]]
  if ? pb.getRepeatedField(1, sublist):
    for item in sublist:
      value.entries.add(? Entry.decode(initProtoBuffer(item)))
  if ? pb.getField(2, field):
    value.full = bool(field)
  ok(value)

proc decode*(_: type Block, pb: ProtoBuffer): ProtoResult[Block] =
  var
    value = Block()
  discard ? pb.getField(1, value.prefix)
  discard ? pb.getField(2, value.data)
  ok(value)

proc decode*(_: type BlockPresence, pb: ProtoBuffer): ProtoResult[BlockPresence] =
  var
    value = BlockPresence()
    field: uint64
  discard ? pb.getField(1, value.cid)
  if ? pb.getField(2, field):
    value.`type` = BlockPresenceType(field)
  discard ? pb.getField(3, value.price)
  ok(value)

proc decode*(_: type AccountMessage, pb: ProtoBuffer): ProtoResult[AccountMessage] =
  var
    value = AccountMessage()
  discard ? pb.getField(1, value.address)
  ok(value)

proc decode*(_: type StateChannelUpdate, pb: ProtoBuffer): ProtoResult[StateChannelUpdate] =
  var
    value = StateChannelUpdate()
  discard ? pb.getField(1, value.update)
  ok(value)

proc ProtobufDecode*(_: type Message, msg: seq[byte]): ProtoResult[Message] =
  var
    value = Message()
    pb = initProtoBuffer(msg)
    ipb: ProtoBuffer
    sublist: seq[seq[byte]]
  if ? pb.getField(1, ipb):
    value.wantlist = ? Wantlist.decode(ipb)
  if ? pb.getRepeatedField(3, sublist):
    for item in sublist:
      value.payload.add(? Block.decode(initProtoBuffer(item)))
  if ? pb.getRepeatedField(4, sublist):
    for item in sublist:
      value.blockPresences.add(? BlockPresence.decode(initProtoBuffer(item)))
  discard ? pb.getField(5, value.pendingBytes)
  if ? pb.getField(6, ipb):
    value.account = ? AccountMessage.decode(ipb)
  if ? pb.getField(7, ipb):
    value.payment = ? StateChannelUpdate.decode(ipb)
  ok(value)
