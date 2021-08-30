import std/sequtils
import pkg/asynctest
import pkg/chronos
import pkg/libp2p

import pkg/dagger/blockexchange/protobuf/presence
import ../../examples

suite "block presence protobuf messages":

  let cid = Cid.example
  let price = UInt256.example
  let presence = Presence(cid: cid, have: true, price: price)
  let message = PresenceMessage.init(presence)

  test "encodes CID":
    check message.cid == cid.data.buffer

  test "encodes have/donthave":
    var presence = presence
    presence.have = true
    check PresenceMessage.init(presence).`type` == presenceHave
    presence.have = false
    check PresenceMessage.init(presence).`type` == presenceDontHave

  test "encodes price":
    check message.price == @(price.toBytesBE)

  test "decodes CID":
    check Presence.init(message).?cid == cid.some

  test "fails to decode when CID is invalid":
    var incorrect = message
    incorrect.cid.del(0)
    check Presence.init(incorrect).isNone

  test "decodes have/donthave":
    var message = message
    message.`type` = presenceHave
    check Presence.init(message).?have == true.some
    message.`type` = presenceDontHave
    check Presence.init(message).?have == false.some

  test "decodes price":
    check Presence.init(message).?price == price.some

  test "fails to decode when price is invalid":
    var incorrect = message
    incorrect.price.add(0)
    check Presence.init(incorrect).isNone
