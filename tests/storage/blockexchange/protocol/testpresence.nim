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
    check Presence.init(message) .? address == address.some

  test "decodes have/donthave":
    var message = message
    message.kind = BlockPresenceType.HaveRange
    check Presence.init(message) .? have == true.some
    message.kind = BlockPresenceType.DontHave
    check Presence.init(message) .? have == false.some
