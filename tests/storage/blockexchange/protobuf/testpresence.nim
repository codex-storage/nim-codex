import pkg/chronos

import pkg/codex/blockexchange/protobuf/presence

import ../../../asynctest
import ../../examples
import ../../helpers

suite "block presence protobuf messages":
  let
    cid = Cid.example
    address = BlockAddress(leaf: false, cid: cid)
    presence = Presence(address: address, have: true)
    message = PresenceMessage.init(presence)

  test "encodes have/donthave":
    var presence = presence
    presence.have = true
    check PresenceMessage.init(presence).`type` == Have
    presence.have = false
    check PresenceMessage.init(presence).`type` == DontHave

  test "decodes CID":
    check Presence.init(message) .? address == address.some

  test "decodes have/donthave":
    var message = message
    message.`type` = BlockPresenceType.Have
    check Presence.init(message) .? have == true.some
    message.`type` = BlockPresenceType.DontHave
    check Presence.init(message) .? have == false.some
