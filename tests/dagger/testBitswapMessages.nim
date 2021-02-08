import std/unittest
import pkg/libp2p
import pkg/dagger/protobuf/bitswap
import pkg/dagger/bitswap/messages
import ../helpers/examples

suite "bitswap messages":

  test "creates message with want list":
    let cid1, cid2 = Cid.example
    let message = Message.want(cid1, cid2)
    check message == Message(wantlist: WantList(entries: @[
      Entry(`block`: cid1.data.buffer),
      Entry(`block`: cid2.data.buffer)
    ]))

  test "creates message that sends blocks":
    let block1, block2 = seq[byte].example
    let message = Message.send(block1, block2)
    check message == Message(payload: @[
      Block(data: block1),
      Block(data: block2)
    ])
