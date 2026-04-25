import pkg/unittest2

import pkg/storage/blockexchange/protocol/message

import ../../examples
import ../../helpers

suite "BlockAddress protobuf encoding":
  test "Should encode and decode block address":
    let
      treeCid = Cid.example
      address = BlockAddress(treeCid: treeCid, index: 42)

    var buffer = initProtoBuffer()
    buffer.write(1, address)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = BlockAddress.decode(decoded)
    check res.isOk
    check res.get.treeCid == treeCid
    check res.get.index == 42

  test "Should encode and decode block address with index 0":
    let
      blockCid = Cid.example
      address = BlockAddress(treeCid: blockCid, index: 0)

    var buffer = initProtoBuffer()
    buffer.write(1, address)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = BlockAddress.decode(decoded)
    check res.isOk
    check res.get.treeCid == blockCid
    check res.get.index == 0

suite "WantListEntry protobuf encoding":
  test "Should encode and decode WantListEntry":
    let
      treeCid = Cid.example
      entry = WantListEntry(
        address: BlockAddress(treeCid: treeCid, index: 10),
        priority: 5,
        cancel: false,
        wantType: WantType.WantHave,
        sendDontHave: true,
        rangeCount: 100,
      )

    var buffer = initProtoBuffer()
    buffer.write(1, entry)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = WantListEntry.decode(decoded)
    check res.isOk
    check res.get.address.treeCid == treeCid
    check res.get.address.index == 10
    check res.get.priority == 5
    check res.get.cancel == false
    check res.get.wantType == WantType.WantHave
    check res.get.sendDontHave == true
    check res.get.rangeCount == 100

  test "Should handle WantListEntry with cancel flag":
    let
      blockCid = Cid.example
      entry = WantListEntry(
        address: BlockAddress(treeCid: blockCid, index: 0),
        priority: 1,
        cancel: true,
        wantType: WantType.WantHave,
        sendDontHave: false,
        rangeCount: 0,
      )

    var buffer = initProtoBuffer()
    buffer.write(1, entry)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = WantListEntry.decode(decoded)
    check res.isOk
    check res.get.cancel == true

suite "WantList protobuf encoding":
  test "Should encode and decode empty WantList":
    let wantList = WantList(entries: @[], full: false)

    var buffer = initProtoBuffer()
    buffer.write(1, wantList)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = WantList.decode(decoded)
    check res.isOk
    check res.get.entries.len == 0
    check res.get.full == false

  test "Should encode and decode WantList with entries":
    let
      treeCid = Cid.example
      wantList = WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: treeCid, index: 0),
            priority: 1,
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: false,
            rangeCount: 10,
          ),
          WantListEntry(
            address: BlockAddress(treeCid: treeCid, index: 1),
            priority: 2,
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: true,
            rangeCount: 0,
          ),
        ],
        full: true,
      )

    var buffer = initProtoBuffer()
    buffer.write(1, wantList)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = WantList.decode(decoded)
    check res.isOk
    check res.get.entries.len == 2
    check res.get.entries[0].rangeCount == 10
    check res.get.entries[1].sendDontHave == true
    check res.get.full == true

suite "BlockPresence protobuf encoding":
  test "Should encode and decode BlockPresence with DontHave":
    let
      treeCid = Cid.example
      presence = BlockPresence(
        address: BlockAddress(treeCid: treeCid, index: 0),
        kind: BlockPresenceType.DontHave,
        ranges: @[],
      )

    var buffer = initProtoBuffer()
    buffer.write(1, presence)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = BlockPresence.decode(decoded)
    check res.isOk
    check res.get.kind == BlockPresenceType.DontHave
    check res.get.ranges.len == 0

  test "Should encode and decode BlockPresence with HaveRange":
    let
      treeCid = Cid.example
      presence = BlockPresence(
        address: BlockAddress(treeCid: treeCid, index: 0),
        kind: BlockPresenceType.HaveRange,
        ranges: @[(start: 0'u64, count: 100'u64), (start: 200'u64, count: 50'u64)],
      )

    var buffer = initProtoBuffer()
    buffer.write(1, presence)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = BlockPresence.decode(decoded)
    check res.isOk
    check res.get.kind == BlockPresenceType.HaveRange
    check res.get.ranges.len == 2
    check res.get.ranges[0].start == 0
    check res.get.ranges[0].count == 100
    check res.get.ranges[1].start == 200
    check res.get.ranges[1].count == 50

  test "Should encode and decode BlockPresence with Complete":
    let
      treeCid = Cid.example
      presence = BlockPresence(
        address: BlockAddress(treeCid: treeCid, index: 0),
        kind: BlockPresenceType.Complete,
        ranges: @[],
      )

    var buffer = initProtoBuffer()
    buffer.write(1, presence)
    buffer.finish()

    var decoded: ProtoBuffer
    check buffer.getField(1, decoded).isOk

    let res = BlockPresence.decode(decoded)
    check res.isOk
    check res.get.kind == BlockPresenceType.Complete

suite "Full Message protobuf encoding":
  test "Should encode and decode empty Message":
    let
      msg = Message(wantList: WantList(entries: @[], full: false), blockPresences: @[])
      encoded = msg.protobufEncode()
      decoded = Message.protobufDecode(encoded)

    check decoded.isOk
    check decoded.get.wantList.entries.len == 0
    check decoded.get.blockPresences.len == 0

  test "Should encode and decode Message with WantList":
    let
      treeCid = Cid.example
      msg = Message(
        wantList: WantList(
          entries: @[
            WantListEntry(
              address: BlockAddress(treeCid: treeCid, index: 0),
              priority: 1,
              cancel: false,
              wantType: WantType.WantHave,
              sendDontHave: false,
              rangeCount: 100,
            )
          ],
          full: false,
        ),
        blockPresences: @[],
      )
      encoded = msg.protobufEncode()
      decoded = Message.protobufDecode(encoded)

    check decoded.isOk
    check decoded.get.wantList.entries.len == 1
    check decoded.get.wantList.entries[0].rangeCount == 100

  test "Should encode and decode Message with BlockPresences":
    let
      treeCid = Cid.example
      msg = Message(
        wantList: WantList(entries: @[], full: false),
        blockPresences: @[
          BlockPresence(
            address: BlockAddress(treeCid: treeCid, index: 0),
            kind: BlockPresenceType.HaveRange,
            ranges: @[(start: 0'u64, count: 500'u64)],
          )
        ],
      )
      encoded = msg.protobufEncode()
      decoded = Message.protobufDecode(encoded)

    check decoded.isOk
    check decoded.get.blockPresences.len == 1
    check decoded.get.blockPresences[0].kind == BlockPresenceType.HaveRange
    check decoded.get.blockPresences[0].ranges.len == 1
    check decoded.get.blockPresences[0].ranges[0].count == 500
