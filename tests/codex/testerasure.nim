import std/sequtils

import pkg/asynctest
import pkg/chronos
import pkg/datastore
import pkg/questionable/results

import pkg/codex/erasure
import pkg/codex/manifest
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/rng

import ./helpers

asyncchecksuite "Erasure encode/decode":
  const BlockSize = 1024'nb
  const dataSetSize = BlockSize * 123 # weird geometry

  var rng: Rng
  var chunker: Chunker
  var manifest: Manifest
  var store: BlockStore
  var erasure: Erasure

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = dataSetSize, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = (dataSetSize * 8), chunkSize = BlockSize)
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    manifest = await storeDataGetManifest(store, chunker)

  proc encode(buffers, parity: int): Future[Manifest] {.async.} =
    let
      encoded = (await erasure.encode(
        manifest,
        buffers,
        parity)).tryGet()

    check:
      encoded.blocksCount mod (buffers + parity) == 0
      encoded.rounded == (manifest.blocksCount + (buffers - (manifest.blocksCount mod buffers)))
      encoded.steps == encoded.rounded div buffers

    return encoded

  test "Should tolerate losing M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand((encoded.blocksCount - 1) div encoded.steps) # random column
      dropped: seq[int]

    for _ in 0..<encoded.ecM:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column.inc(encoded.steps - 1)

    var
      decoded = (await erasure.decode(encoded)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == encoded.originalCid
      decoded.blocksCount == encoded.originalBlocksCount

    for d in dropped:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Should not tolerate losing more than M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand((encoded.blocksCount - 1) div encoded.steps) # random column
      dropped: seq[int]

    for _ in 0..<encoded.ecM + 1:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column.inc(encoded.steps)

    var
      decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

    for d in dropped:
      let present = await store.hasBlock(manifest.treeCid, d)
      check not present.tryGet()

  test "Should tolerate losing M data blocks in M random columns":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      blocks: seq[int]
      offset = 0

    while offset < encoded.steps - 1:
      let
        blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.steps))

      for _ in 0..<encoded.ecM:
        blocks.add(rng.sample(blockIdx, blocks))
      offset.inc

    for idx in blocks:
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      (await store.delBlock(manifest.treeCid, idx)).tryGet()
      discard

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0..<manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Should not tolerate losing more than M data blocks in M random columns":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      blocks: seq[int]
      offset = 0

    while offset < encoded.steps - 1:
      let
        blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.steps))

      for _ in 0..<encoded.ecM + 1: # NOTE: the +1
        var idx: int
        while true:
          idx = rng.sample(blockIdx, blocks)
          let blk = (await store.getBlock(encoded.treeCid, idx)).tryGet()
          if not blk.isEmpty:
            break

        blocks.add(idx)
      offset.inc

    for idx in blocks:
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      (await store.delBlock(manifest.treeCid, idx)).tryGet()
      discard

    var
      decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous data blocks":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    for b in 0..<encoded.steps * encoded.ecM:
      (await store.delBlock(encoded.treeCid, b)).tryGet()
      (await store.delBlock(manifest.treeCid, b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0..<manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous parity blocks":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    for b in (encoded.blocksCount - encoded.steps * encoded.ecM)..<encoded.blocksCount:
      (await store.delBlock(encoded.treeCid, b)).tryGet()
      (await store.delBlock(manifest.treeCid, b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0..<manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "handles edge case of 0 parity blocks":
    const
      buffers = 20
      parity = 0

    let encoded = await encode(buffers, parity)

    discard (await erasure.decode(encoded)).tryGet()
