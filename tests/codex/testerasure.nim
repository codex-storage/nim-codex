import std/sequtils
import std/sugar
import std/times

import pkg/chronos
import pkg/questionable/results

import pkg/codex/erasure
import pkg/codex/manifest
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/rng
import pkg/codex/utils
import pkg/codex/indexingstrategy
import pkg/taskpools
import pkg/codex/utils/arrayutils

import ../asynctest
import ./helpers
import ./examples

suite "Erasure encode/decode":
  const BlockSize = 1024'nb
  const dataSetSize = BlockSize * 123 # weird geometry

  var rng: Rng
  var chunker: Chunker
  var manifest: Manifest
  var store: BlockStore
  var erasure: Erasure
  let repoTmp = TempLevelDb.new()
  let metaTmp = TempLevelDb.new()
  var taskpool: Taskpool

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = dataSetSize, chunkSize = BlockSize)
    store = RepoStore.new(repoDs, metaDs)
    taskpool = Taskpool.new()
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, taskpool)
    manifest = await storeDataGetManifest(store, chunker)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()
    taskpool.shutdown()

  proc encode(buffers, parity: int): Future[Manifest] {.async.} =
    let encoded =
      (await erasure.encode(manifest, buffers.Natural, parity.Natural)).tryGet()

    check:
      encoded.blocksCount mod (buffers + parity) == 0
      encoded.rounded == roundUp(manifest.blocksCount, buffers)
      encoded.steps == encoded.rounded div buffers

    return encoded

  test "Should tolerate losing M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand((encoded.blocksCount div encoded.steps) - 1) # random column
      dropped: seq[int]

    for _ in 0 ..< encoded.ecM:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column = (column + encoded.steps) mod encoded.blocksCount # wrap around

    var decoded = (await erasure.decode(encoded)).tryGet()

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
      column = rng.rand((encoded.blocksCount div encoded.steps) - 1) # random column
      dropped: seq[int]

    for _ in 0 ..< encoded.ecM + 1:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column = (column + encoded.steps) mod encoded.blocksCount # wrap around

    var decoded: Manifest

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
      let blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.steps))

      for _ in 0 ..< encoded.ecM:
        blocks.add(rng.sample(blockIdx, blocks))
      offset.inc

    for idx in blocks:
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      (await store.delBlock(manifest.treeCid, idx)).tryGet()
      discard

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0 ..< manifest.blocksCount:
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

    while offset < encoded.steps:
      let blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.steps))

      for _ in 0 ..< encoded.ecM + 1: # NOTE: the +1
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

    var decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous data blocks":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    # loose M original (systematic) symbols/blocks
    for b in 0 ..< (encoded.steps * encoded.ecM):
      (await store.delBlock(encoded.treeCid, b)).tryGet()
      (await store.delBlock(manifest.treeCid, b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0 ..< manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous parity blocks":
    const
      buffers = 20
      parity = 10

    let
      encoded = await encode(buffers, parity)
      blocks = collect:
        for i in 0 .. encoded.blocksCount:
          i

    # loose M parity (all!) symbols/blocks from the dataset
    for b in blocks[^(encoded.steps * encoded.ecM) ..^ 1]:
      (await store.delBlock(encoded.treeCid, b)).tryGet()
      (await store.delBlock(manifest.treeCid, b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0 ..< manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Handles edge case of 0 parity blocks":
    const
      buffers = 20
      parity = 0

    let encoded = await encode(buffers, parity)

    discard (await erasure.decode(encoded)).tryGet()

  test "Should concurrently encode/decode multiple datasets":
    const iterations = 5

    let
      datasetSize = 1.MiBs
      ecK = 10.Natural
      ecM = 10.Natural

    var encodeTasks = newSeq[Future[?!Manifest]]()
    var decodeTasks = newSeq[Future[?!Manifest]]()
    var manifests = newSeq[Manifest]()
    for i in 0 ..< iterations:
      let
        # create random data and store it
        blockSize = rng.sample(@[1, 2, 4, 8, 16, 32, 64].mapIt(it.KiBs))
        chunker = RandomChunker.new(rng, size = datasetSize, chunkSize = blockSize)
        manifest = await storeDataGetManifest(store, chunker)
      manifests.add(manifest)
      # encode the data concurrently
      encodeTasks.add(erasure.encode(manifest, ecK, ecM))
    # wait for all encoding tasks to finish
    let encodeResults = await allFinished(encodeTasks)
    # decode the data concurrently
    for i in 0 ..< encodeResults.len:
      decodeTasks.add(erasure.decode(encodeResults[i].read().tryGet()))
    # wait for all decoding tasks to finish
    let decodeResults = await allFinished(decodeTasks) # TODO: use allFutures 

    for j in 0 ..< decodeTasks.len:
      let
        decoded = decodeResults[j].read().tryGet()
        encoded = encodeResults[j].read().tryGet()
      check:
        decoded.treeCid == manifests[j].treeCid
        decoded.treeCid == encoded.originalTreeCid
        decoded.blocksCount == encoded.originalBlocksCount

  test "Should handle verifiable manifests":
    const
      buffers = 20
      parity = 10

    let
      encoded = await encode(buffers, parity)
      slotCids = collect(newSeq):
        for i in 0 ..< encoded.numSlots:
          Cid.example

      verifiable = Manifest.new(encoded, Cid.example, slotCids).tryGet()

      decoded = (await erasure.decode(verifiable)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == verifiable.originalTreeCid
      decoded.blocksCount == verifiable.originalBlocksCount

  for i in 1 .. 5:
    test "Should encode/decode using various parameters " & $i & "/5":
      let
        blockSize = rng.sample(@[1, 2, 4, 8, 16, 32, 64].mapIt(it.KiBs))
        datasetSize = 1.MiBs
        ecK = 10.Natural
        ecM = 10.Natural

      let
        chunker = RandomChunker.new(rng, size = datasetSize, chunkSize = blockSize)
        manifest = await storeDataGetManifest(store, chunker)
        encoded = (await erasure.encode(manifest, ecK, ecM)).tryGet()
        decoded = (await erasure.decode(encoded)).tryGet()

      check:
        decoded.treeCid == manifest.treeCid
        decoded.treeCid == encoded.originalTreeCid
        decoded.blocksCount == encoded.originalBlocksCount

  test "Should complete encode/decode task when cancelled":
    let
      blocksLen = 10000
      parityLen = 10
      data = seq[seq[byte]].new()
      chunker = RandomChunker.new(
        rng, size = (blocksLen * BlockSize.int), chunkSize = BlockSize
      )

    data[].setLen(blocksLen)

    for i in 0 ..< blocksLen:
      let chunk = await chunker.getBytes()
      shallowCopy(data[i], @(chunk))

    let
      parity = createDoubleArray(parityLen, BlockSize.int)
      paritySeq = seq[seq[byte]].new()
      recovered = createDoubleArray(blocksLen, BlockSize.int)
      cancelledTaskParity = createDoubleArray(parityLen, BlockSize.int)
      cancelledTaskRecovered = createDoubleArray(blocksLen, BlockSize.int)

    paritySeq[].setLen(parityLen)
    defer:
      freeDoubleArray(parity, parityLen)
      freeDoubleArray(cancelledTaskParity, parityLen)
      freeDoubleArray(recovered, blocksLen)
      freeDoubleArray(cancelledTaskRecovered, blocksLen)

    for i in 0 ..< parityLen:
      paritySeq[i] = cast[seq[byte]](parity[i])

    # call asyncEncode to get the parity
    let encFut =
      await erasure.asyncEncode(BlockSize.int, blocksLen, parityLen, data, parity)
    check encFut.isOk

    let decFut = await erasure.asyncDecode(
      BlockSize.int, blocksLen, parityLen, data, paritySeq, recovered
    )
    check decFut.isOk

    # call asyncEncode and cancel the task
    let encodeFut = erasure.asyncEncode(
      BlockSize.int, blocksLen, parityLen, data, cancelledTaskParity
    )
    encodeFut.cancel()

    try:
      discard await encodeFut
    except CatchableError as exc:
      check exc of CancelledError
    finally:
      for i in 0 ..< parityLen:
        check equalMem(parity[i], cancelledTaskParity[i], BlockSize.int)

    # call asyncDecode and cancel the task
    let decodeFut = erasure.asyncDecode(
      BlockSize.int, blocksLen, parityLen, data, paritySeq, cancelledTaskRecovered
    )
    decodeFut.cancel()

    try:
      discard await decodeFut
    except CatchableError as exc:
      check exc of CancelledError
    finally:
      for i in 0 ..< blocksLen:
        check equalMem(recovered[i], cancelledTaskRecovered[i], BlockSize.int)
