## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/sequtils
import std/sugar

import pkg/chronos
import pkg/chronicles
import pkg/libp2p/[multicodec, cid, multibase, multihash]
import pkg/libp2p/protobuf/minprotobuf

import ../manifest
import ../merkletree
import ../stores
import ../blocktype as bt
import ../utils
import ../utils/asynciter

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

  EncoderProvider* = proc(size, blocks, parity: int): EncoderBackend
    {.raises: [Defect], noSideEffect.}

  DecoderProvider* = proc(size, blocks, parity: int): DecoderBackend
    {.raises: [Defect], noSideEffect.}

  Erasure* = ref object
    encoderProvider*: EncoderProvider
    decoderProvider*: DecoderProvider
    store*: BlockStore

  EncodingParams = object
    ecK: int
    ecM: int
    interleave: int
    rounded: int # padded number of blocks
    steps: int
    blocksCount: int # total number of blocks including padding en EC

func oldIndexToPos(params: EncodingParams, idx: int): int {.inline.} =
  ## Convert an index to a position in the encoded
  ##  dataset
  ## `idx`  - the index to convert
  ## `step` - the current step
  ## `pos`  - the position in the encoded dataset
  ##

  #(idx div params.interleave) mod (params.ecK + params.ecM)
  (idx div params.interleave) mod (params.ecK)

func newIndexToPos(encoded: Manifest, idx: int): int {.inline.} =
  (idx div encoded.interleave) mod (encoded.ecK + encoded.ecM)

func newIndex(params: EncodingParams, step, column, pos: int): int =
  #params.rounded + step + params.steps * pos
  #step + params.steps * pos
  step * params.interleave * (params.ecK + params.ecM) + pos * params.interleave + column

func newIndex(params: Manifest, step, column, pos: int): int =
  #params.rounded + step + params.steps * pos
  #step + encoded.steps * pos
  step * params.interleave * (params.ecK + params.ecM) + pos * params.interleave + column

func oldIndex(params: EncodingParams, step, column, pos: int): int =
  #params.rounded + step + params.steps * pos
  #step + encoded.steps * pos
  step * params.interleave * (params.ecK) + pos * params.interleave + column

func oldIndex(params: Manifest, step, column, pos: int): int =
  #params.rounded + step + params.steps * pos
  #step + encoded.steps * pos
  step * params.interleave * (params.ecK) + pos * params.interleave + column

iterator oldIndices(params: EncodingParams, step, column: int): int =
  for i in 0 ..< params.ecK:
    yield oldIndex(params, step, column, i)

iterator newIndices(params: Manifest, step, column: int): int =
  for i in 0 ..< params.ecK + params.ecM:
    yield newIndex(params, step, column, i)

proc getPendingBlocks(
  self: Erasure,
  manifest: Manifest,
  indicies: seq[int]): AsyncIter[(?!bt.Block, int)] =
  ## Get pending blocks iterator
  ##

  var
    # request blocks from the store
    pendingBlocks = indicies.map( (i: int) =>
      self.store.getBlock(BlockAddress.init(manifest.treeCid, i)).map((r: ?!bt.Block) => (r, i)) # Get the data blocks (first K)
    )

  proc isFinished(): bool = pendingBlocks.len == 0

  proc genNext(): Future[(?!bt.Block, int)] {.async.} =
    let completedFut = await one(pendingBlocks)
    if (let i = pendingBlocks.find(completedFut); i >= 0):
      pendingBlocks.del(i)
      return await completedFut
    else:
      let (_, index) = await completedFut
      raise newException(CatchableError, "Future for block id not found, tree cid: " & $manifest.treeCid & ", index: " & $index)

  Iter.new(genNext, isFinished)

proc prepareEncodingData(
  self: Erasure,
  manifest: Manifest,
  params: EncodingParams,
  step: int,
  column: int,
  data: ref seq[seq[byte]],
  cids: ref seq[Cid],
  emptyBlock: seq[byte]): Future[?!int] {.async.} =
  ## Prepare data for encoding
  ##

  let
    indicies = toSeq(oldIndices(params, step, column))
    pendingBlocksIter = self.getPendingBlocks(manifest, indicies.filterIt(it < manifest.blocksCount))

  var resolved = 0
  for fut in pendingBlocksIter:
    let (blkOrErr, idx) = await fut
    without blk =? blkOrErr, err:
      warn "Failed retreiving a block", treeCid = manifest.treeCid, idx, msg = err.msg
      continue
    
    let pos = oldIndexToPos(params, idx)
    let newidx = newIndex(params, step, column, pos)
    shallowCopy(data[pos], if blk.isEmpty: emptyBlock else: blk.data)
    cids[newidx] = blk.cid

    resolved.inc()

  for idx in indicies.filterIt(it >= manifest.blocksCount):
    let pos = oldIndexToPos(params, idx)
    let newidx = newIndex(params, step, column, pos)
    trace "Padding with empty block", idx, newidx
    shallowCopy(data[pos], emptyBlock)
    without emptyBlockCid =? emptyCid(manifest.version, manifest.hcodec, manifest.codec), err:
      return failure(err)
    cids[newidx] = emptyBlockCid

  success(resolved)

proc prepareDecodingData(
  self: Erasure,
  encoded: Manifest,
  step: int,
  column: int,
  data: ref seq[seq[byte]],
  parityData: ref seq[seq[byte]],
  cids: ref seq[Cid],
  emptyBlock: seq[byte]): Future[?!(int, int)] {.async.} =
  ## Prepare data for decoding
  ## `encoded`    - the encoded manifest
  ## `step`       - the current step
  ## `data`       - the data to be prepared
  ## `parityData` - the parityData to be prepared
  ## `cids`       - cids of prepared data
  ## `emptyBlock` - the empty block to be used for padding
  ##

  let 
    indicies = toSeq(newIndices(encoded, step, column))
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

    let
      pos = newIndexToPos(encoded, idx)

    logScope:
      cid   = blk.cid
      idx   = idx
      pos   = pos
      step  = step
      empty = blk.isEmpty

    cids[idx] = blk.cid
    if pos >= encoded.ecK:
      trace "Retrieved parity block"
      shallowCopy(parityData[pos - encoded.ecK], if blk.isEmpty: emptyBlock else: blk.data)
      parityPieces.inc
    else:
      trace "Retrieved data block"
      shallowCopy(data[pos], if blk.isEmpty: emptyBlock else: blk.data)
      dataPieces.inc

    resolved.inc

  return success (dataPieces, parityPieces)

proc init(_: type EncodingParams, manifest: Manifest, ecK, ecM, interl: int): ?!EncodingParams =
  ## Calculate erasure coding parameters.
  ## interl: if 0, use the interleaving resulting in a single "step". Otherwise use the given value, and calculate the number of steps needed.
  if ecK > manifest.blocksCount:
    return failure("Unable to encode manifest, not enough blocks, ecK = " & $ecK & ", blocksCount = " & $manifest.blocksCount)

  let interleave = 
    if interl == 0: divUp(manifest.blocksCount, ecK)
    else: interl

  let
    rounded = roundUp(manifest.blocksCount, interleave * ecK)
    steps = divUp(manifest.blocksCount, interleave * ecK)
    blocksCount = rounded + (steps * interleave * ecM)

  EncodingParams(
    ecK: ecK,
    ecM: ecM,
    interleave: interleave,
    rounded: rounded,
    steps: steps,
    blocksCount: blocksCount
  ).success

proc encodeData(
  self: Erasure,
  manifest: Manifest,
  params: EncodingParams
  ): Future[?!Manifest] {.async.} =
  ## Encode blocks pointed to by the protected manifest
  ##
  ## `manifest` - the manifest to encode
  ##

  logScope:
    steps           = params.steps
    rounded_blocks  = params.rounded
    blocks_count    = params.blocksCount
    ecK             = params.ecK
    ecM             = params.ecM
    interleave      = params.interleave

  var
    cids = seq[Cid].new()
    encoder = self.encoderProvider(manifest.blockSize.int, params.ecK, params.ecM)
    emptyBlock = newSeq[byte](manifest.blockSize.int)

  cids[].setLen(params.blocksCount)

  try:
    for step in 0..<params.steps:
      for column in 0..<params.interleave:
      # TODO: Don't allocate a new seq every time, allocate once and zero out
        var
          data = seq[seq[byte]].new() # number of blocks to encode
          parityData = newSeqWith[seq[byte]](params.ecM, newSeq[byte](manifest.blockSize.int))

        data[].setLen(params.ecK)
        # TODO: this is a tight blocking loop so we sleep here to allow
        # other events to be processed, this should be addressed
        # by threading
        await sleepAsync(10.millis)

        without resolved =?
          (await self.prepareEncodingData(manifest, params, step, column, data, cids, emptyBlock)), err:
            trace "Unable to prepare data", error = err.msg
            return failure(err)

        trace "Erasure coding data", data = data[].len, parity = parityData.len

        if (
          let res = encoder.encode(data[], parityData);
          res.isErr):
          trace "Unable to encode manifest!", error = $res.error
          return failure($res.error)

        for j in 0..<params.ecM:
          without blk =? bt.Block.new(parityData[j]), error:
            trace "Unable to create parity block", err = error.msg
            return failure(error)

          let idx = newIndex(params, step, column, params.ecK + j)
          trace "Adding parity block", cid = blk.cid, idx
          cids[idx] = blk.cid
          if isErr (await self.store.putBlock(blk)):
            trace "Unable to store block!", cid = blk.cid
            return failure("Unable to store block!")

    without tree =? MerkleTree.init(cids[]), err:
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
      interleave = params.interleave #TODO
    )

    return encodedManifest.success
  except CancelledError as exc:
    trace "Erasure coding encoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding encoding error", exc = exc.msg
    return failure(exc)
  finally:
    encoder.release()

proc encode*(
  self: Erasure,
  manifest: Manifest,
  blocks: int,
  parity: int,
  interleave: int = 0): Future[?!Manifest] {.async.} =
  ## Encode a manifest into one that is erasure protected.
  ##
  ## `manifest`   - the original manifest to be encoded
  ## `blocks`     - the number of blocks to be encoded - K
  ## `parity`     - the number of parity blocks to generate - M
  ##

  without params =? EncodingParams.init(manifest, blocks, parity, interleave), err:
    return failure(err)

  without encodedManifest =? await self.encodeData(manifest, params), err:
    return failure(err)

  return success encodedManifest

proc encodeMulti*(
  self: Erasure,
  manifest: Manifest,
  code: seq[(int,int)]): Future[?!Manifest] {.async.} =
  ## Encode a manifest into one that is erasure protected in multiple dimensions.
  ##
  ## code: list of (K,M) RS code parameter pairs

  var
    mfest = manifest
    i = 1

  for (k,m) in code:
    mfest = (await self.encode(mfest, k, m, i)).tryGet()
    i *= (k+m)

  return success mfest


proc decode*(
    self: Erasure,
    encoded: Manifest
): Future[?!Manifest] {.async.} =
  ## Decode a protected manifest into it's original
  ## manifest
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be recovered
  ##

  logScope:
    steps           = encoded.steps
    rounded_blocks  = encoded.rounded
    new_manifest    = encoded.blocksCount

  var
    cids = seq[Cid].new()
    recoveredIndices = newSeq[int]()
    decoder = self.decoderProvider(encoded.blockSize.int, encoded.ecK, encoded.ecM)
    emptyBlock = newSeq[byte](encoded.blockSize.int)


  cids[].setLen(encoded.blocksCount)
  try:
    for step in 0..<encoded.steps:
      for column in 0..<encoded.interleave:
        # TODO: this is a tight blocking loop so we sleep here to allow
        # other events to be processed, this should be addressed
        # by threading
        await sleepAsync(10.millis)

        var
          data = seq[seq[byte]].new()
          parityData = seq[seq[byte]].new()
          recovered = newSeqWith[seq[byte]](encoded.ecK, newSeq[byte](encoded.blockSize.int))

        data[].setLen(encoded.ecK)        # set len to K
        parityData[].setLen(encoded.ecM)  # set len to M

        without (dataPieces, parityPieces) =?
          (await self.prepareDecodingData(encoded, step, column, data, parityData, cids, emptyBlock)), err:
          trace "Unable to prepare data", error = err.msg
          return failure(err)

        if dataPieces >= encoded.ecK:
          trace "Retrieved all the required data blocks"
          continue

        trace "Erasure decoding data"
        if (
          let err = decoder.decode(data[], parityData[], recovered);
          err.isErr):
          trace "Unable to decode data!", err = $err.error
          return failure($err.error)

        for i in 0..<encoded.ecK:
          let idx = newIndex(encoded, step, column, i)
          if data[i].len <= 0 and not cids[idx].isEmpty:
            without blk =? bt.Block.new(recovered[i]), error:
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

  # fill old cid list
  var oldCids = seq[Cid].new()
  oldCids[].setLen(encoded.originalBlocksCount)
  for step in 0..<encoded.steps:
    for column in 0..<encoded.interleave:
      for i in 0..<encoded.ecK:
        let idx = newIndex(encoded, step, column, i)
        let oldIdx = oldIndex(encoded, step, column, i)
        if oldIdx < encoded.originalBlocksCount:
          oldCids[oldIdx] = cids[idx]

  without tree =? MerkleTree.init(oldCids[]), err:
    return failure(err)

  without treeCid =? tree.rootCid, err:
    return failure(err)

  if treeCid != encoded.originalTreeCid:
    return failure("Original tree root differs from the tree root computed out of recovered data")

  let idxIter = Iter
    .fromItems(recoveredIndices)
    .filter((i: int) => i < tree.leavesCount)

  if err =? (await self.store.putSomeProofs(tree, idxIter)).errorOption:
      return failure(err)

  let decoded = Manifest.new(encoded)

  return decoded.success

proc decodeMulti*(
    self: Erasure,
    encoded: Manifest
): Future[?!Manifest] {.async.} =
  ## Decode a protected manifest into it's original unprotected
  ## manifest
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be recovered
  ##

  var
    mfest = encoded

  while mfest.protected:
    mfest = (await self.decode(mfest)).tryGet()

  return success mfest


proc start*(self: Erasure) {.async.} =
  return

proc stop*(self: Erasure) {.async.} =
  return

proc new*(
    T: type Erasure,
    store: BlockStore,
    encoderProvider: EncoderProvider,
    decoderProvider: DecoderProvider
): Erasure =
  ## Create a new Erasure instance for encoding and decoding manifests

  Erasure(
    store: store,
    encoderProvider: encoderProvider,
    decoderProvider: decoderProvider)
