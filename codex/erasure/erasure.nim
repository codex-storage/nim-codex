## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push:
  {.upraises: [].}

import std/[sugar, atomics, sequtils]

import pkg/chronos
import pkg/chronos/threadsync
import pkg/chronicles
import pkg/libp2p/[multicodec, cid, multihash]
import pkg/libp2p/protobuf/minprotobuf
import pkg/taskpools

import ../logutils
import ../manifest
import ../merkletree
import ../stores
import ../blocktype as bt
import ../utils
import ../utils/asynciter
import ../indexingstrategy
import ../errors
import ../utils/arrayutils

import pkg/stew/byteutils

import ./backend

export backend

logScope:
  topics = "codex erasure"

type
  ## Encode a manifest into one that is erasure protected.
  ##
  ## The new manifest has K `blocks` that are encoded into
  ## additional M `parity` blocks. The resulting dataset
  ## is padded with empty blocks if it doesn't have a square
  ## shape.
  ##
  ## NOTE: The padding blocks could be excluded
  ## from transmission, but they aren't for now.
  ##
  ## The resulting dataset is logically divided into rows
  ## where a row is made up of B blocks. There are then,
  ## K + M = N rows in total, each of length B blocks. Rows
  ## are assumed to be of the same number of (B) blocks.
  ##
  ## The encoding is systematic and the rows can be
  ## read sequentially by any node without decoding.
  ##
  ## Decoding is possible with any K rows or partial K
  ## columns (with up to M blocks missing per column),
  ## or any combination there of.
  ##
  EncoderProvider* =
    proc(size, blocks, parity: int): EncoderBackend {.raises: [Defect], noSideEffect.}

  DecoderProvider* =
    proc(size, blocks, parity: int): DecoderBackend {.raises: [Defect], noSideEffect.}

  Erasure* = ref object
    taskPool: Taskpool
    encoderProvider*: EncoderProvider
    decoderProvider*: DecoderProvider
    store*: BlockStore

  EncodingParams = object
    ecK: Natural
    ecM: Natural
    rounded: Natural
    steps: Natural
    blocksCount: Natural
    strategy: StrategyType

  ErasureError* = object of CodexError
  InsufficientBlocksError* = object of ErasureError
    # Minimum size, in bytes, that the dataset must have had
    # for the encoding request to have succeeded with the parameters
    # provided.
    minSize*: NBytes

  EncodeTask = object
    success: Atomic[bool]
    erasure: ptr Erasure
    blocks: ptr UncheckedArray[ptr UncheckedArray[byte]]
    parity: ptr UncheckedArray[ptr UncheckedArray[byte]]
    blockSize, blocksLen, parityLen: int
    signal: ThreadSignalPtr

  DecodeTask = object
    success: Atomic[bool]
    erasure: ptr Erasure
    blocks: ptr UncheckedArray[ptr UncheckedArray[byte]]
    parity: ptr UncheckedArray[ptr UncheckedArray[byte]]
    recovered: ptr UncheckedArray[ptr UncheckedArray[byte]]
    blockSize, blocksLen: int
    parityLen, recoveredLen: int
    signal: ThreadSignalPtr

func indexToPos(steps, idx, step: int): int {.inline.} =
  ## Convert an index to a position in the encoded
  ##  dataset
  ## `idx`  - the index to convert
  ## `step` - the current step
  ## `pos`  - the position in the encoded dataset
  ##

  (idx - step) div steps

proc getPendingBlocks(
    self: Erasure, manifest: Manifest, indicies: seq[int]
): AsyncIter[(?!bt.Block, int)] =
  ## Get pending blocks iterator
  ##

  var
    # request blocks from the store
    pendingBlocks = indicies.map(
      (i: int) =>
        self.store.getBlock(BlockAddress.init(manifest.treeCid, i)).map(
          (r: ?!bt.Block) => (r, i)
        ) # Get the data blocks (first K)
    )

  proc isFinished(): bool =
    pendingBlocks.len == 0

  proc genNext(): Future[(?!bt.Block, int)] {.async.} =
    let completedFut = await one(pendingBlocks)
    if (let i = pendingBlocks.find(completedFut); i >= 0):
      pendingBlocks.del(i)
      return await completedFut
    else:
      let (_, index) = await completedFut
      raise newException(
        CatchableError,
        "Future for block id not found, tree cid: " & $manifest.treeCid & ", index: " &
          $index,
      )

  AsyncIter[(?!bt.Block, int)].new(genNext, isFinished)

proc prepareEncodingData(
    self: Erasure,
    manifest: Manifest,
    params: EncodingParams,
    step: Natural,
    data: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyBlock: seq[byte],
): Future[?!Natural] {.async.} =
  ## Prepare data for encoding
  ##

  let
    strategy = params.strategy.init(
      firstIndex = 0, lastIndex = params.rounded - 1, iterations = params.steps
    )
    indicies = toSeq(strategy.getIndicies(step))
    pendingBlocksIter =
      self.getPendingBlocks(manifest, indicies.filterIt(it < manifest.blocksCount))

  var resolved = 0
  for fut in pendingBlocksIter:
    let (blkOrErr, idx) = await fut
    without blk =? blkOrErr, err:
      warn "Failed retreiving a block", treeCid = manifest.treeCid, idx, msg = err.msg
      continue

    let pos = indexToPos(params.steps, idx, step)
    shallowCopy(data[pos], if blk.isEmpty: emptyBlock else: blk.data)
    cids[idx] = blk.cid

    resolved.inc()

  for idx in indicies.filterIt(it >= manifest.blocksCount):
    let pos = indexToPos(params.steps, idx, step)
    trace "Padding with empty block", idx
    shallowCopy(data[pos], emptyBlock)
    without emptyBlockCid =? emptyCid(manifest.version, manifest.hcodec, manifest.codec),
      err:
      return failure(err)
    cids[idx] = emptyBlockCid

  success(resolved.Natural)

proc prepareDecodingData(
    self: Erasure,
    encoded: Manifest,
    step: Natural,
    data: ref seq[seq[byte]],
    parityData: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyBlock: seq[byte],
): Future[?!(Natural, Natural)] {.async.} =
  ## Prepare data for decoding
  ## `encoded`    - the encoded manifest
  ## `step`       - the current step
  ## `data`       - the data to be prepared
  ## `parityData` - the parityData to be prepared
  ## `cids`       - cids of prepared data
  ## `emptyBlock` - the empty block to be used for padding
  ##

  let
    strategy = encoded.protectedStrategy.init(
      firstIndex = 0, lastIndex = encoded.blocksCount - 1, iterations = encoded.steps
    )
    indicies = toSeq(strategy.getIndicies(step))
    pendingBlocksIter = self.getPendingBlocks(encoded, indicies)

  var
    dataPieces = 0
    parityPieces = 0
    resolved = 0
  for fut in pendingBlocksIter:
    # Continue to receive blocks until we have just enough for decoding
    # or no more blocks can arrive
    if resolved >= encoded.ecK:
      break

    let (blkOrErr, idx) = await fut
    without blk =? blkOrErr, err:
      trace "Failed retreiving a block", idx, treeCid = encoded.treeCid, msg = err.msg
      continue

    let pos = indexToPos(encoded.steps, idx, step)

    logScope:
      cid = blk.cid
      idx = idx
      pos = pos
      step = step
      empty = blk.isEmpty

    cids[idx] = blk.cid
    if idx >= encoded.rounded:
      trace "Retrieved parity block"
      shallowCopy(
        parityData[pos - encoded.ecK], if blk.isEmpty: emptyBlock else: blk.data
      )
      parityPieces.inc
    else:
      trace "Retrieved data block"
      shallowCopy(data[pos], if blk.isEmpty: emptyBlock else: blk.data)
      dataPieces.inc

    resolved.inc

  return success (dataPieces.Natural, parityPieces.Natural)

proc init*(
    _: type EncodingParams,
    manifest: Manifest,
    ecK: Natural,
    ecM: Natural,
    strategy: StrategyType,
): ?!EncodingParams =
  if ecK > manifest.blocksCount:
    let exc = (ref InsufficientBlocksError)(
      msg:
        "Unable to encode manifest, not enough blocks, ecK = " & $ecK &
        ", blocksCount = " & $manifest.blocksCount,
      minSize: ecK.NBytes * manifest.blockSize,
    )
    return failure(exc)

  let
    rounded = roundUp(manifest.blocksCount, ecK)
    steps = divUp(rounded, ecK)
    blocksCount = rounded + (steps * ecM)

  success EncodingParams(
    ecK: ecK,
    ecM: ecM,
    rounded: rounded,
    steps: steps,
    blocksCount: blocksCount,
    strategy: strategy,
  )

proc leopardEncodeTask(tp: Taskpool, task: ptr EncodeTask) {.gcsafe.} =
  # Task suitable for running in taskpools - look, no GC!
  let encoder =
    task[].erasure.encoderProvider(task[].blockSize, task[].blocksLen, task[].parityLen)
  defer:
    encoder.release()
    discard task[].signal.fireSync()

  if (
    let res =
      encoder.encode(task[].blocks, task[].parity, task[].blocksLen, task[].parityLen)
    res.isErr
  ):
    warn "Error from leopard encoder backend!", error = $res.error

    task[].success.store(false)
  else:
    task[].success.store(true)

proc encodeAsync*(
    self: Erasure,
    blockSize, blocksLen, parityLen: int,
    data: ref seq[seq[byte]],
    parity: ptr UncheckedArray[ptr UncheckedArray[byte]],
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without threadPtr =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    threadPtr.close().expect("closing once works")

  var blockData = createDoubleArray(blocksLen, blockSize)

  for i in 0 ..< data[].len:
    copyMem(blockData[i], addr data[i][0], blockSize)

  defer:
    freeDoubleArray(blockData, blocksLen)

  ## Create an ecode task with block data 
  var task = EncodeTask(
    erasure: addr self,
    blockSize: blockSize,
    blocksLen: blocksLen,
    parityLen: parityLen,
    blocks: blockData,
    parity: parity,
    signal: threadPtr,
  )

  let t = addr task

  doAssert self.taskPool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  self.taskPool.spawn leopardEncodeTask(self.taskPool, t)
  let threadFut = threadPtr.wait()

  try:
    await threadFut.join()
  except CatchableError as exc:
    try:
      await threadFut
    except AsyncError as asyncExc:
      return failure(asyncExc.msg)
    finally:
      if exc of CancelledError:
        raise (ref CancelledError) exc
      else:
        return failure(exc.msg)

  if not t.success.load():
    return failure("Leopard encoding failed")

  success()

proc encodeData(
    self: Erasure, manifest: Manifest, params: EncodingParams
): Future[?!Manifest] {.async.} =
  ## Encode blocks pointed to by the protected manifest
  ##
  ## `manifest` - the manifest to encode
  ##
  logScope:
    steps = params.steps
    rounded_blocks = params.rounded
    blocks_count = params.blocksCount
    ecK = params.ecK
    ecM = params.ecM

  var
    cids = seq[Cid].new()
    emptyBlock = newSeq[byte](manifest.blockSize.int)

  cids[].setLen(params.blocksCount)

  try:
    for step in 0 ..< params.steps:
      # TODO: Don't allocate a new seq every time, allocate once and zero out
      var
        data = seq[seq[byte]].new() # number of blocks to encode
        parity = createDoubleArray(params.ecM, manifest.blockSize.int)

      data[].setLen(params.ecK)
      # TODO: this is a tight blocking loop so we sleep here to allow
      # other events to be processed, this should be addressed
      # by threading
      await sleepAsync(10.millis)

      without resolved =?
        (await self.prepareEncodingData(manifest, params, step, data, cids, emptyBlock)),
        err:
        trace "Unable to prepare data", error = err.msg
        return failure(err)

      trace "Erasure coding data", data = data[].len

      try:
        if err =? (
          await self.encodeAsync(
            manifest.blockSize.int, params.ecK, params.ecM, data, parity
          )
        ).errorOption:
          return failure(err)
      except CancelledError as exc:
        raise exc
      finally:
        freeDoubleArray(parity, params.ecM)

      var idx = params.rounded + step
      for j in 0 ..< params.ecM:
        var innerPtr: ptr UncheckedArray[byte] = parity[][j]
        without blk =? bt.Block.new(innerPtr.toOpenArray(0, manifest.blockSize.int - 1)),
          error:
          trace "Unable to create parity block", err = error.msg
          return failure(error)

        trace "Adding parity block", cid = blk.cid, idx
        cids[idx] = blk.cid
        if isErr (await self.store.putBlock(blk)):
          trace "Unable to store block!", cid = blk.cid
          return failure("Unable to store block!")
        idx.inc(params.steps)

    without tree =? CodexTree.init(cids[]), err:
      return failure(err)

    without treeCid =? tree.rootCid, err:
      return failure(err)

    if err =? (await self.store.putAllProofs(tree)).errorOption:
      return failure(err)

    let encodedManifest = Manifest.new(
      manifest = manifest,
      treeCid = treeCid,
      datasetSize = (manifest.blockSize.int * params.blocksCount).NBytes,
      ecK = params.ecK,
      ecM = params.ecM,
      strategy = params.strategy,
    )

    trace "Encoded data successfully", treeCid, blocksCount = params.blocksCount
    success encodedManifest
  except CancelledError as exc:
    trace "Erasure coding encoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding encoding error", exc = exc.msg
    return failure(exc)

proc encode*(
    self: Erasure,
    manifest: Manifest,
    blocks: Natural,
    parity: Natural,
    strategy = SteppedStrategy,
): Future[?!Manifest] {.async.} =
  ## Encode a manifest into one that is erasure protected.
  ##
  ## `manifest`   - the original manifest to be encoded
  ## `blocks`     - the number of blocks to be encoded - K
  ## `parity`     - the number of parity blocks to generate - M
  ##

  without params =? EncodingParams.init(manifest, blocks.int, parity.int, strategy), err:
    return failure(err)

  without encodedManifest =? await self.encodeData(manifest, params), err:
    return failure(err)

  return success encodedManifest

proc leopardDecodeTask(tp: Taskpool, task: ptr DecodeTask) {.gcsafe.} =
  # Task suitable for running in taskpools - look, no GC!
  let decoder =
    task[].erasure.decoderProvider(task[].blockSize, task[].blocksLen, task[].parityLen)
  defer:
    decoder.release()

  if (
    let res = decoder.decode(
      task[].blocks,
      task[].parity,
      task[].recovered,
      task[].blocksLen,
      task[].parityLen,
      task[].recoveredLen,
    )
    res.isErr
  ):
    warn "Error from leopard decoder backend!", error = $res.error
    task[].success.store(false)
  else:
    task[].success.store(true)

  discard task[].signal.fireSync()

proc decodeAsync*(
    self: Erasure,
    blockSize, blocksLen, parityLen: int,
    blocks, parity: ref seq[seq[byte]],
    recovered: ptr UncheckedArray[ptr UncheckedArray[byte]],
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without threadPtr =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    threadPtr.close().expect("closing once works")

  var
    blocksData = createDoubleArray(blocksLen, blockSize)
    parityData = createDoubleArray(parityLen, blockSize)

  for i in 0 ..< blocks[].len:
    if blocks[i].len > 0:
      copyMem(blocksData[i], addr blocks[i][0], blockSize)
    else:
      blocksData[i] = nil

  for i in 0 ..< parity[].len:
    if parity[i].len > 0:
      copyMem(parityData[i], addr parity[i][0], blockSize)
    else:
      parityData[i] = nil

  defer:
    freeDoubleArray(blocksData, blocksLen)
    freeDoubleArray(parityData, parityLen)

  ## Create an decode task with block data 
  var task = DecodeTask(
    erasure: addr self,
    blockSize: blockSize,
    blocksLen: blocksLen,
    parityLen: parityLen,
    recoveredLen: blocksLen,
    blocks: blocksData,
    parity: parityData,
    recovered: recovered,
    signal: threadPtr,
  )

  # Hold the task pointer until the signal is received
  let t = addr task
  doAssert self.taskPool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  self.taskPool.spawn leopardDecodeTask(self.taskPool, t)
  let threadFut = threadPtr.wait()

  try:
    await threadFut.join()
  except CatchableError as exc:
    try:
      await threadFut
    except AsyncError as asyncExc:
      return failure(asyncExc.msg)
    finally:
      if exc of CancelledError:
        raise (ref CancelledError) exc
      else:
        return failure(exc.msg)

  if not t.success.load():
    return failure("Leopard encoding failed")

  success()

proc decode*(self: Erasure, encoded: Manifest): Future[?!Manifest] {.async.} =
  ## Decode a protected manifest into it's original
  ## manifest
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be recovered
  ##
  logScope:
    steps = encoded.steps
    rounded_blocks = encoded.rounded
    new_manifest = encoded.blocksCount

  var
    cids = seq[Cid].new()
    recoveredIndices = newSeq[Natural]()
    decoder = self.decoderProvider(encoded.blockSize.int, encoded.ecK, encoded.ecM)
    emptyBlock = newSeq[byte](encoded.blockSize.int)

  cids[].setLen(encoded.blocksCount)
  try:
    for step in 0 ..< encoded.steps:
      # TODO: this is a tight blocking loop so we sleep here to allow
      # other events to be processed, this should be addressed
      # by threading
      await sleepAsync(10.millis)

      var
        data = seq[seq[byte]].new()
        parityData = seq[seq[byte]].new()
        recovered = createDoubleArray(encoded.ecK, encoded.blockSize.int)

      data[].setLen(encoded.ecK) # set len to K
      parityData[].setLen(encoded.ecM) # set len to M

      without (dataPieces, _) =? (
        await self.prepareDecodingData(
          encoded, step, data, parityData, cids, emptyBlock
        )
      ), err:
        trace "Unable to prepare data", error = err.msg
        return failure(err)

      if dataPieces >= encoded.ecK:
        trace "Retrieved all the required data blocks"
        continue

      trace "Erasure decoding data"
      try:
        if err =? (
          await self.decodeAsync(
            encoded.blockSize.int, encoded.ecK, encoded.ecM, data, parityData, recovered
          )
        ).errorOption:
          return failure(err)
      except CancelledError as exc:
        raise exc
      finally:
        freeDoubleArray(recovered, encoded.ecK)

      for i in 0 ..< encoded.ecK:
        let idx = i * encoded.steps + step
        if data[i].len <= 0 and not cids[idx].isEmpty:
          var innerPtr: ptr UncheckedArray[byte] = recovered[][i]

          without blk =? bt.Block.new(
            innerPtr.toOpenArray(0, encoded.blockSize.int - 1)
          ), error:
            trace "Unable to create block!", exc = error.msg
            return failure(error)

          trace "Recovered block", cid = blk.cid, index = i
          if isErr (await self.store.putBlock(blk)):
            trace "Unable to store block!", cid = blk.cid
            return failure("Unable to store block!")

          cids[idx] = blk.cid
          recoveredIndices.add(idx)
  except CancelledError as exc:
    trace "Erasure coding decoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding decoding error", exc = exc.msg
    return failure(exc)
  finally:
    decoder.release()

  without tree =? CodexTree.init(cids[0 ..< encoded.originalBlocksCount]), err:
    return failure(err)

  without treeCid =? tree.rootCid, err:
    return failure(err)

  if treeCid != encoded.originalTreeCid:
    return failure(
      "Original tree root differs from the tree root computed out of recovered data"
    )

  let idxIter =
    Iter[Natural].new(recoveredIndices).filter((i: Natural) => i < tree.leavesCount)

  if err =? (await self.store.putSomeProofs(tree, idxIter)).errorOption:
    return failure(err)

  let decoded = Manifest.new(encoded)

  return decoded.success

proc start*(self: Erasure) {.async.} =
  return

proc stop*(self: Erasure) {.async.} =
  return

proc new*(
    T: type Erasure,
    store: BlockStore,
    encoderProvider: EncoderProvider,
    decoderProvider: DecoderProvider,
    taskPool: Taskpool,
): Erasure =
  ## Create a new Erasure instance for encoding and decoding manifests
  ##
  Erasure(
    store: store,
    encoderProvider: encoderProvider,
    decoderProvider: decoderProvider,
    taskPool: taskPool,
  )
