import std/sequtils

import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import pkg/dagger/erasure
import pkg/dagger/manifest
import pkg/dagger/stores
import pkg/dagger/blocktype
import pkg/dagger/rng

import ./helpers

suite "Erasure encode/decode":
  test "Should tolerate loosing M data blocks in a single random column":
    const
      buffers = 20
      parity = 10
      dataSetSize = BlockSize * 123 # weird geometry

    var
      chunker = RandomChunker.new(Rng.instance(), size = dataSetSize, chunkSize = BlockSize)
      manifest = Manifest.new(blockSize = BlockSize).tryGet()
      store = CacheStore.new(cacheSize = (dataSetSize * 2), chunkSize = BlockSize)
      erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
      rng = Rng.instance

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      check (await store.putBlock(blk))

    let
      encoded = (await erasure.encode(
        manifest,
        buffers,
        parity)).tryGet()

    check:
      encoded.len mod (buffers + parity) == 0
      encoded.rounded == (manifest.len + (buffers - (manifest.len mod buffers)))
      encoded.steps == encoded.rounded div buffers

    var
      column = rng.rand(encoded.len div encoded.steps) # random column
      dropped: seq[Cid]

    for _ in 0..<encoded.M:
      dropped.add(encoded[column])
      check (await store.delBlock(encoded[column]))
      column.inc(encoded.steps)

    var
      decoded = (await erasure.decode(encoded)).tryGet()

    check:
      decoded.cid.tryGet() == manifest.cid.tryGet()
      decoded.cid.tryGet() == encoded.originalCid
      decoded.len == encoded.originalLen

    for d in dropped:
      check d in store

  test "Should tolerate loosing M data blocks in multiple random columns":
    const
      buffers = 20
      parity = 10
      dataSetSize = BlockSize * 123 # weird geometry

    var
      chunker = RandomChunker.new(Rng.instance(), size = dataSetSize, chunkSize = BlockSize)
      manifest = Manifest.new(blockSize = BlockSize).tryGet()
      store = CacheStore.new(cacheSize = (dataSetSize * 5), chunkSize = BlockSize)
      erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
      rng = Rng.instance

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      check (await store.putBlock(blk))

    let
      encoded = (await erasure.encode(
        manifest,
        buffers,
        parity)).tryGet()

    check:
      encoded.len mod (buffers + parity) == 0
      encoded.rounded == (manifest.len + (buffers - (manifest.len mod buffers)))
      encoded.steps == encoded.rounded div buffers

    var
      blocks: seq[int]
      offset = 0

    while offset < encoded.steps - 1:
      let
        blockIdx = toSeq(countup(offset, encoded.len - 1, encoded.steps))

      var count = 0
      for _ in 0..<encoded.M:
        blocks.add(rng.sample(blockIdx, blocks))
        count.inc

      offset.inc

    for idx in blocks:
      check (await store.delBlock(encoded[idx]))

    var
      decoded = (await erasure.decode(encoded)).tryGet()

    for d in manifest:
      check d in store
