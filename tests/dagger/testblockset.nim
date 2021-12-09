import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils

import pkg/dagger/chunker
import pkg/dagger/blocktype as bt
import pkg/dagger/blockset

import ./helpers

suite "BlockSet":
  test "Should produce valid tree hash checksum":
    let
      blockSet = BlockSetRef.new(
        blocks = @[
            Block.new("Block 1".toBytes).cid,
            Block.new("Block 2".toBytes).cid,
            Block.new("Block 3".toBytes).cid,
            Block.new("Block 4".toBytes).cid,
            Block.new("Block 5".toBytes).cid,
            Block.new("Block 6".toBytes).cid,
            Block.new("Block 7".toBytes).cid,
          ])

      checksum = @[18.byte, 32, 14, 78, 178, 161,
                  50, 175, 26, 57, 68, 6, 163, 128,
                  19, 131, 212, 203, 93, 98, 219,
                  34, 243, 217, 132, 191, 86, 255,
                  171, 160, 77, 167, 91, 145]

    var mh: MultiHash
    if MultiHash.decode(checksum, mh).tryGet() < -1:
      fail

    let checkSumCid = Cid.init(blockSet.version, blockSet.codec, mh).tryGet()

    let res = blockSet.treeHash()
    if h =? res:
      check h == checkSumCid
      return

    check false
