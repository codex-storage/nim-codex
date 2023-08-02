import pkg/libp2p/[cid, multicodec, multihash]
import pkg/codex/blocktype
from ./helpers import `==`
import unittest2

suite "Blocktypes":
  setup:
    let cid0 = Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n").get()
  test "emptyCids should work":
    let sha2 = multiCodec("sha2-256")
    let cid = emptyCid(CIDv0, sha2)

    check cid.isOk
    check cid.get() == cid0

  test "emptyDigest should work":
    let sha2 = multiCodec("sha2-256")
    let dig = emptyDigest(CIDv0, sha2)

    check dig.isOk
    check dig.get() == cid0.mhash.get()

  test "emptyBlock should work":
    let sha2 = multiCodec("sha2-256")
    let blk = emptyBlock(CIDv0, sha2)

    check blk.isOk
    check blk.get() == Block(cid: cid0)
