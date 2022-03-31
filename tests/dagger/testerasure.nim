import pkg/asynctest
import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import pkg/dagger/erasure
import pkg/dagger/manifest
import pkg/dagger/stores
import pkg/dagger/blocktype
import pkg/dagger/rng

import ./helpers

suite "Erasure":
  var
    chunker: Chunker
    manifest: Manifest
    store: BlockStore
    erasure: Erasure

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = BlockSize * 127, chunkSize = BlockSize)
    manifest = Manifest.new().tryGet()
    store = CacheStore.new()
    erasure = Erasure.new(leoEncoderProvider, leoDecoderProvider)

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      check (await store.putBlock(blk))

  test "Test manifest encode":
    var encoded = (await erasure.encode(manifest, store, 10, 5)).tryGet()
    echo encoded.len
