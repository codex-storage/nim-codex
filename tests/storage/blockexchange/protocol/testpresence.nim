import std/options

import pkg/chronos

import pkg/storage/blockexchange/protocol/presence

import ../../../asynctest
import ../../examples
import ../../helpers

suite "Block presence protobuf messages":
  let
    cid = Cid.example
    address = BlockAddress(treeCid: cid, index: 0)
    presence =
      Presence(address: address, have: true, presenceType: BlockPresenceType.HaveRange)
    message = PresenceMessage.init(presence)

  test "encodes have/donthave":
    var presence = presence
    presence.presenceType = BlockPresenceType.HaveRange
    check PresenceMessage.init(presence).kind == BlockPresenceType.HaveRange
    presence.presenceType = BlockPresenceType.DontHave
    check PresenceMessage.init(presence).kind == BlockPresenceType.DontHave

  test "decodes CID":
    let p = Presence.init(message)
    check p.isSome
    check p.get.address == address

  test "decodes have/donthave":
    var message = message
    message.kind = BlockPresenceType.HaveRange
    let pHave = Presence.init(message)
    check pHave.isSome
    check pHave.get.have == true
    message.kind = BlockPresenceType.DontHave
    let pDontHave = Presence.init(message)
    check pDontHave.isSome
    check pDontHave.get.have == false
