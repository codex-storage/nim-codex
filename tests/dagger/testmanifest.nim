import std/sequtils

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils

import pkg/dagger/chunker
import pkg/dagger/blocktype as bt
import pkg/dagger/manifest

import ./helpers

suite "Manifest":
  test "Should produce valid tree hash checksum":
    without var manifest =? Manifest.init(
        blocks = @[
            Block.init("Block 1".toBytes).tryGet().cid,
            Block.init("Block 2".toBytes).tryGet().cid,
            Block.init("Block 3".toBytes).tryGet().cid,
            Block.init("Block 4".toBytes).tryGet().cid,
            Block.init("Block 5".toBytes).tryGet().cid,
            Block.init("Block 6".toBytes).tryGet().cid,
            Block.init("Block 7".toBytes).tryGet().cid,
          ]):
        fail()

    let
      checksum = @[18.byte, 32, 227, 176, 196, 66, 152,
                  252, 28, 20, 154, 251, 244, 200, 153,
                  111, 185, 36, 39, 174, 65, 228, 100,
                  155, 147, 76, 164, 149, 153, 27, 120,
                  82, 184, 85]

    var mh: MultiHash
    check MultiHash.decode(checksum, mh).tryGet() > 0

    let checkSumCid = Cid.init(manifest.version, manifest.codec, mh).tryGet()
    check checkSumCid == manifest.cid.tryGet()

  test "Should encode/decode to/from manifest":
    let
      blocks = (0..<1000).mapIt(
        Block.init(("Block " & $it).toBytes).tryGet().cid
      )

    var
      blocksManifest = Manifest.init(blocks).tryGet()

    let
      e = blocksManifest.encode().tryGet()
      manifest = Manifest.decode(e).tryGet()

    check manifest.blocks == blocks
