import std/sequtils

import pkg/chronos
import pkg/questionable/results
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils

import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/manifest

import ./helpers

suite "Manifest":
  test "Should produce valid tree hash checksum":
    var manifest = Manifest.new(
        blocks = @[
            Block.new("Block 1".toBytes).tryGet().cid,
            Block.new("Block 2".toBytes).tryGet().cid,
            Block.new("Block 3".toBytes).tryGet().cid,
            Block.new("Block 4".toBytes).tryGet().cid,
            Block.new("Block 5".toBytes).tryGet().cid,
            Block.new("Block 6".toBytes).tryGet().cid,
            Block.new("Block 7".toBytes).tryGet().cid,
          ]).tryGet()

    let
      encoded = @[byte 18, 32, 227, 176, 196, 66, 152,
                  252, 28, 20, 154, 251, 244, 200, 153,
                  111, 185, 36, 39, 174, 65, 228, 100,
                  155, 147, 76, 164, 149, 153, 27, 120,
                  82, 184, 85]

    var mh: MultiHash
    check MultiHash.decode(encoded, mh).tryGet() > 0

    let encodedCid = Cid.init(manifest.version, manifest.codec, mh).tryGet()
    check:
      encodedCid == manifest.cid.tryGet()

  test "Should encode/decode to/from manifest":
    let
      blocks = (0..<1000).mapIt(
        Block.new(("Block " & $it).toBytes).tryGet().cid
      )

    var
      manifest = Manifest.new(blocks).tryGet()

    let
      e = manifest.encode().tryGet()
      decoded = Manifest.decode(e).tryGet()

    check:
      decoded.blocks == blocks
      decoded.protected == false

  test "Should produce a protected manifest":
    let
      blocks = (0..<333).mapIt(
        Block.new(("Block " & $it).toBytes).tryGet().cid
      )
      manifest = Manifest.new(blocks).tryGet()
      protected = Manifest.new(manifest, 2, 2).tryGet()

    check:
        protected.originalCid == manifest.cid.tryGet()
        protected.blocks[0..<333] == manifest.blocks
        protected.protected == true
        protected.originalLen == manifest.len

    # fill up with empty Cid's
    for i in protected.rounded..<protected.len:
      protected.blocks[i] = EmptyCid[manifest.version]
        .catch
        .get()[manifest.hcodec]
        .catch
        .get()

    var
      encoded = protected.encode().tryGet()
      decoded = Manifest.decode(encoded).tryGet()

    check:
      decoded.protected == true
      decoded.originalLen == manifest.len

      decoded.ecK == protected.ecK
      decoded.ecM == protected.ecM

      decoded.originalCid == protected.originalCid
      decoded.originalCid == manifest.cid.tryGet()

      decoded.blocks == protected.blocks
      decoded.blocks[0..<333] == manifest.blocks
