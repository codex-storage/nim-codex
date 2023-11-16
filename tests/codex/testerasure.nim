import std/sequtils
import std/sugar

import pkg/asynctest
import pkg/chronos
import pkg/datastore
import pkg/questionable/results

import pkg/codex/erasure
import pkg/codex/manifest
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/rng
import pkg/codex/utils

import ./helpers

asyncchecksuite "Erasure encode/decode":
  const BlockSize = 64'nb
  const dataSetSize = BlockSize * 20 # weird geometry

  var rng: Rng
  var chunker: Chunker
  var manifest: Manifest
  var store: BlockStore
  var erasure: Erasure

  setup:
    let
      repoDs = SQLiteDatastore.new(Memory).tryGet()
      metaDs = SQLiteDatastore.new(Memory).tryGet()
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = dataSetSize, chunkSize = BlockSize)
    store = RepoStore.new(repoDs, metaDs)
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    manifest = await storeDataGetManifest(store, chunker)

  proc encode(buffers, parity: int, interleave: int = 0,
              manifest: Manifest = manifest): Future[Manifest] {.async.} =
    let
      encoded = (await erasure.encode(
        manifest,
        buffers,
        parity, interleave)).tryGet()

    check:
      encoded.blocksCount mod (buffers + parity) == 0
      #encoded.rounded == (manifest.blocksCount + (buffers - (manifest.blocksCount mod buffers)))
      encoded.steps == (encoded.rounded - 1) div (buffers * encoded.interleave) + 1

    return encoded

  test "Should tolerate losing M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand(encoded.interleave - 1) # random column
      dropped: seq[int]

    for _ in 0..<encoded.ecM:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column.inc(encoded.interleave)

    var
      decoded = (await erasure.decode(encoded)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == encoded.originalTreeCid
      decoded.blocksCount == encoded.originalBlocksCount

    for d in dropped:
      if d < manifest.blocksCount: # we don't support returning parity blocks yet
        let present = await store.hasBlock(manifest.treeCid, d)
        check present.tryGet()

  test "Should not tolerate losing more than M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand(encoded.interleave - 1) # random column
      dropped: seq[int]

    for _ in 0..<encoded.ecM + 1:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column.inc(encoded.interleave)

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

    while offset < encoded.interleave - 1:
      let
        blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.interleave))

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

    while offset < encoded.interleave:
      let
        blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.interleave))

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

    # loose M original (systematic) symbols/blocks
    for b in 0..<(encoded.interleave * encoded.ecM):
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

    let
      encoded = await encode(buffers, parity)
      blocks = collect:
        for i in 0..encoded.blocksCount:
          i

    # loose M parity (all!) symbols/blocks from the dataset
    for b in blocks[^(encoded.interleave * encoded.ecM)..^1]:
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

  test "Encode without interleaving (horizontal): Should tolerate losing M data blocks in a single random row":
    const
      buffers = 20
      parity = 10
      interleave = 1

    let encoded = await encode(buffers, parity, interleave)

    var
      idx = rng.rand(encoded.steps - 1) # random row
      dropped: seq[int]

    for _ in 0..<encoded.ecM:
      dropped.add(idx)
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      (await store.delBlock(manifest.treeCid, idx)).tryGet()
      idx.inc(encoded.interleave)

    var
      decoded = (await erasure.decode(encoded)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == encoded.originalTreeCid
      decoded.blocksCount == encoded.originalBlocksCount

    for d in dropped:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Encode without interleaving (horizontal): Should not tolerate losing M+1 data blocks in a single random row":
    const
      buffers = 20
      parity = 10
      interleave = 1

    let encoded = await encode(buffers, parity, interleave)

    var
      idx = rng.rand(encoded.steps - 1) # random row
      dropped: seq[int]

    for _ in 0..<encoded.ecM + 1:
      dropped.add(idx)
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      (await store.delBlock(manifest.treeCid, idx)).tryGet()
      idx.inc(encoded.interleave)

    var
      decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

    for d in dropped:
      let present = await store.hasBlock(manifest.treeCid, d)
      check not present.tryGet()


  test "2D encode: Should tolerate losing M data blocks in a single random row":
    const
      k1 = 7
      m1 = 3
      i1 = 1
      k2 = 5
      m2 = 2
      i2 = k1 + m1

    let
      encoded1 = await encode(k1, m1, i1)
      encoded2 = await encode(k2, m2, i2, encoded1)

    var
      idx = rng.rand(encoded2.steps - 1) # random row
      dropped: seq[int]

    for _ in 0..<encoded2.ecM:
      dropped.add(idx)
      (await store.delBlock(encoded2.treeCid, idx)).tryGet()
      idx.inc(encoded2.interleave)

    var
      decoded1 = (await erasure.decode(encoded2)).tryGet()
      decoded = (await erasure.decode(decoded1)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == encoded1.originalTreeCid
      decoded.blocksCount == encoded1.originalBlocksCount

    for d in dropped:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "3D encode: Should tolerate losing M data blocks in a single random row":
    const
      k1 = 7
      m1 = 3
      i1 = 1
      k2 = 5
      m2 = 2
      i2 = k1 + m1
      k3 = 3
      m3 = 1
      i3 = i1 * (k2 + m2)

    let
      encoded1 = await encode(k1, m1, i1)
      encoded2 = await encode(k2, m2, i2, encoded1)
      encoded3 = await encode(k3, m3, i3, encoded2)

    var
      idx = rng.rand(encoded3.steps - 1) # random row
      dropped: seq[int]

    for _ in 0..<encoded3.ecM:
      dropped.add(idx)
      (await store.delBlock(encoded3.treeCid, idx)).tryGet()
      idx.inc(encoded3.interleave)

    var
      decoded2 = (await erasure.decode(encoded3)).tryGet()
      decoded1 = (await erasure.decode(decoded2)).tryGet()
      decoded = (await erasure.decode(decoded1)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == encoded1.originalTreeCid
      decoded.blocksCount == encoded1.originalBlocksCount

    for d in dropped:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "3D encode: test multi-dimensional API":
    const
      encoding = @[(7, 3),(5, 2),(3, 1)]

    let
      encoded = (await erasure.encodeMulti(manifest, encoding)).tryGet()
      decoded = (await erasure.decodeMulti(encoded)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.blocksCount == encoded.unprotectedBlocksCount

  test "3D encode: test multi-dimensional API with drop":
    const
      encoding = @[(7, 3),(5, 2),(3, 1)]

    let encoded = (await erasure.encodeMulti(manifest, encoding)).tryGet()

    var
      idx = rng.rand(encoded.steps - 1) # random row
      dropped: seq[int]

    for _ in 0..<encoded.ecM:
      dropped.add(idx)
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      idx.inc(encoded.interleave)

    let decoded = (await erasure.decodeMulti(encoded)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.blocksCount == encoded.unprotectedBlocksCount
