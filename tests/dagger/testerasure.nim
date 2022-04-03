import std/random
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

randomize()

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
      column = rand(0..(encoded.len div encoded.steps)) # random column
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
