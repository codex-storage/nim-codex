import std/sequtils
import std/strutils

import pkg/unittest2

import pkg/storage/blockexchange/protocol/constants
import pkg/storage/blockexchange/protocol/message

import ../../examples
import ../../helpers

suite "Full Message protobuf encoding":
  test "Should encode and decode empty Message":
    let
      msg = Message(wantList: WantList(entries: @[], full: false), blockPresences: @[])
      encoded = msg.encode()
      decoded = Message.decode(encoded)

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
      encoded = msg.encode()
      decoded = Message.decode(encoded)

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
            ranges: @[Range(start: 0'u64, count: 500'u64)],
          )
        ],
      )
      encoded = msg.encode()
      decoded = Message.decode(encoded)

    check decoded.isOk
    check decoded.get.blockPresences.len == 1
    check decoded.get.blockPresences[0].kind == BlockPresenceType.HaveRange
    check decoded.get.blockPresences[0].ranges.len == 1
    check decoded.get.blockPresences[0].ranges[0].count == 500

  test "Should reject Message with too many blockPresences":
    let
      treeCid = Cid.example
      msg = Message(
        wantList: WantList(entries: @[], full: false),
        blockPresences: newSeqWith(
          MaxBlockPresenceEntries + 1,
          BlockPresence(
            address: BlockAddress(treeCid: treeCid, index: 0),
            kind: BlockPresenceType.DontHave,
            ranges: @[],
          ),
        ),
      )
      encoded = msg.encode()
      decoded = Message.decode(encoded)

    check decoded.isErr
    check "exceeds" in decoded.error.msg

  test "Should reject Message with too many wantList entries":
    let
      treeCid = Cid.example
      msg = Message(
        wantList: WantList(
          entries: newSeqWith(
            MaxWantListEntries + 1,
            WantListEntry(
              address: BlockAddress(treeCid: treeCid, index: 0),
              priority: 1,
              cancel: false,
              wantType: WantType.WantHave,
              sendDontHave: false,
              rangeCount: 0,
            ),
          ),
          full: false,
        ),
        blockPresences: @[],
      )
      encoded = msg.encode()
      decoded = Message.decode(encoded)

    check decoded.isErr
    check "exceeds" in decoded.error.msg
