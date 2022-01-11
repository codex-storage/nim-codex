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
    without var manifest =? BlocksManifest.init(
        blocks = @[
            Block.init("Block 1".toBytes).get().cid,
            Block.init("Block 2".toBytes).get().cid,
            Block.init("Block 3".toBytes).get().cid,
            Block.init("Block 4".toBytes).get().cid,
            Block.init("Block 5".toBytes).get().cid,
            Block.init("Block 6".toBytes).get().cid,
            Block.init("Block 7".toBytes).get().cid,
          ]):
        fail()

    let
      checksum = @[18.byte, 32, 14, 78, 178, 161,
                  50, 175, 26, 57, 68, 6, 163, 128,
                  19, 131, 212, 203, 93, 98, 219,
                  34, 243, 217, 132, 191, 86, 255,
                  171, 160, 77, 167, 91, 145]

    var mh: MultiHash
    check MultiHash.decode(checksum, mh).get() > 0

    let checkSumCid = Cid.init(manifest.version, manifest.codec, mh).get()
    check checkSumCid == !(manifest.cid)

  test "Should encode/decode to/from manifest":
    let
      blocks = (0..<1000).mapIt(
        Block.init(("Block " & $it).toBytes).get().cid
      )

    var
      manifest = BlocksManifest.init(blocks).get()

    let
      e = manifest.encode().get()
      (cid, decoded) = BlocksManifest.decode(e).get()

    check decoded == blocks
