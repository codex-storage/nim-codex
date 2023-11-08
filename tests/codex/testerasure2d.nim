import std/sequtils
from std/math import sqrt

import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/questionable/results

import pkg/codex/erasure
import pkg/codex/manifest
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/rng

import ./helpers

suite "2D Erasure encode/decode":

  const BlockSize = 1024
  const dataSetSize = BlockSize * 123

  var rng: Rng
  var chunker: Chunker
  var manifest: Manifest
  var store: BlockStore
  var erasure: Erasure

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = dataSetSize, chunkSize = BlockSize)
    manifest = !Manifest.new(blockSize = BlockSize)
    store = CacheStore.new(cacheSize = (dataSetSize * 2), chunkSize = BlockSize)
    erasure = Erasure.new(store, leoEncoderProvider2D, leoDecoderProvider2D)

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      (await store.putBlock(blk)).tryGet()

  proc encode(buffers, parity: int): Future[Manifest] {.async.} =
    let
      encoded = (await erasure.encode(
        manifest,
        buffers,
        parity)).tryGet()

    check:
      encoded.len mod (buffers + parity) == 0
      encoded.rounded == manifest.len - 1 + buffers - (manifest.len - 1) mod buffers
      encoded.steps == encoded.rounded div buffers

    echo(manifest.blocks)
    echo(encoded.blocks)

    return encoded

  test "Should tolerate losing M1 data blocks in a single random column":
    const
      k1 = 3
      k2 = k1
      m1 = 1
      m2 = m1
      buffers = k1 * k2
      parity = (k1+m1) * (k2+m2) - buffers

    echo "encode"

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand(encoded.steps - 1) # random column
      dropped: seq[Cid]

    echo ("steps", encoded.steps)
    for _ in 0 ..< m1:
      echo ("column", column)
      dropped.add(encoded[column])
      (await store.delBlock(encoded[column])).tryGet()
      column.inc(encoded.steps)

    var
      decoded = (await erasure.decode(encoded, parity + buffers - dropped.len)).tryGet()

    check:
      decoded.cid.tryGet() == manifest.cid.tryGet()
      decoded.cid.tryGet() == encoded.originalCid
      decoded.len == encoded.originalLen

    for d in dropped:
      let present = await store.hasBlock(d)
      check present.tryGet()
