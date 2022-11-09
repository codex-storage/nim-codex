import std/sequtils

import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import pkg/codex/erasure
import pkg/codex/manifest
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/rng

import ./helpers

suite "Erasure encode/decode":

  const BlockSize = 1024
  const dataSetSize = BlockSize * 123 # weird geometry

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
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)

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
      encoded.rounded == (manifest.len + (buffers - (manifest.len mod buffers)))
      encoded.steps == encoded.rounded div buffers

    return encoded

  test "Should tolerate losing M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand(encoded.len div encoded.steps) # random column
      dropped: seq[Cid]

    for _ in 0..<encoded.M:
      dropped.add(encoded[column])
      (await store.delBlock(encoded[column])).tryGet()
      column.inc(encoded.steps)

    var
      decoded = (await erasure.decode(encoded)).tryGet()

    check:
      decoded.cid.tryGet() == manifest.cid.tryGet()
      decoded.cid.tryGet() == encoded.originalCid
      decoded.len == encoded.originalLen

    for d in dropped:
      let present = await store.hasBlock(d)
      check present.tryGet()

  test "Should not tolerate losing more than M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand(encoded.len div encoded.steps) # random column
      dropped: seq[Cid]

    for _ in 0..<encoded.M + 1:
      dropped.add(encoded[column])
      (await store.delBlock(encoded[column])).tryGet()
      column.inc(encoded.steps)

    var
      decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

    for d in dropped:
      let present = await store.hasBlock(d)
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
        blockIdx = toSeq(countup(offset, encoded.len - 1, encoded.steps))

      for _ in 0..<encoded.M:
        blocks.add(rng.sample(blockIdx, blocks))
      offset.inc

    for idx in blocks:
      (await store.delBlock(encoded[idx])).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in manifest:
      let present = await store.hasBlock(d)
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
        blockIdx = toSeq(countup(offset, encoded.len - 1, encoded.steps))

      for _ in 0..<encoded.M + 1: # NOTE: the +1
        var idx: int
        while true:
          idx = rng.sample(blockIdx, blocks)
          if not encoded[idx].isEmpty:
            break

        blocks.add(idx)
      offset.inc

    for idx in blocks:
      (await store.delBlock(encoded[idx])).tryGet()

    var
      decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous data blocks":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    for b in encoded.blocks[0..<encoded.steps * encoded.M]:
      (await store.delBlock(b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in manifest:
      let present = await store.hasBlock(d)
      check present.tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous parity blocks":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    for b in encoded.blocks[^(encoded.steps * encoded.M)..^1]:
      (await store.delBlock(b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in manifest:
      let present = await store.hasBlock(d)
      check present.tryGet()

  test "handles edge case of 0 parity blocks":
    const
      buffers = 20
      parity = 0

    let encoded = await encode(buffers, parity)

    discard (await erasure.decode(encoded)).tryGet()
