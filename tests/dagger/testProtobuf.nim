import std/unittest
import pkg/libp2p
import pkg/protobuf_serialization
import pkg/dagger/protobuf/bitswap
import ../helpers/examples

suite "protobuf messages":

  test "serializes bitswap want lists":
    let cid = Cid.example
    let entry = Entry(`block`: cid.data.buffer)
    let wantlist = WantList(entries: @[entry])
    let message = Message(wantlist: wantlist)

    let encoded = Protobuf.encode(message)

    check Protobuf.decode(encoded, Message) == message

  test "serializes bitswap blocks":
    let bloc = Block(data: seq[byte].example)
    let message = Message(payload: @[bloc])

    let encoded = Protobuf.encode(message)

    check Protobuf.decode(encoded, Message) == message
