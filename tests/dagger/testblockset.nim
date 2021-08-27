
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils as stew

import pkg/dagger/chunker
import pkg/dagger/rng
import pkg/dagger/blocktype as bt
import pkg/dagger/blockstream
import pkg/dagger/blockset

import ./helpers

suite "Data set":
  test "Should produce valid tree hash checksum":
    let
      blocks = @[
            !Block.new("Block 1".toBytes),
            !Block.new("Block 2".toBytes),
            !Block.new("Block 3".toBytes),
            !Block.new("Block 4".toBytes),
            !Block.new("Block 5".toBytes),
            !Block.new("Block 6".toBytes),
            !Block.new("Block 7".toBytes),
          ]

      checksum = @[byte(43), 2, 105, 202, 45, 227,
                  178, 211, 83, 246, 56, 250, 210,
                  160, 210, 98, 123, 87, 139, 157,
                  188, 221, 252, 255, 17, 11, 79,
                  85, 220, 161, 238, 108]

    var idx = 0
    proc nextBlockHandler(): ?!Block =
      let blk = if idx < blocks.len: blocks[idx] else: return
      idx.inc()
      return success blk

    let
      blockStream = TestStream(handler: nextBlockHandler)
      blockSet = BlockSetRef.new(stream = blockStream)

    let res = blockSet.treeHash()
    check res.isOK
    if h =? res:
      check h.hashBytes() == checksum
      return

    check false
