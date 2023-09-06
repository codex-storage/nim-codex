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
import std/options

import pkg/chronos
import pkg/chronicles
import pkg/questionable

import ../manifest
import ../stores
import ../blocktype as bt

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

  GetNext = proc(): Future[?(bt.Block, int)] {.upraises: [], gcsafe, closure.}
  PendingBlocksIter* = ref object
    finished*: bool
    next*: GetNext

func indexToPos(self: Erasure, encoded: Manifest, idx, step: int): int {.inline.} =
  ## Convert an index to a position in the encoded
  ##  dataset
  ## `idx`  - the index to convert
  ## `step` - the current step
  ## `pos`  - the position in the encoded dataset
  ##

  (idx - step) div encoded.steps

iterator items*(blocks: PendingBlocksIter): Future[?(bt.Block, int)] =
  while not blocks.finished:
    yield blocks.next()

proc getPendingBlocks(
  self: Erasure,
  manifest: Manifest,
  start, stop, steps: int): ?!PendingBlocksIter =
  ## Get pending blocks iterator
  ##

  var
    # calculate block indexes to retrieve
    blockIdx = toSeq(countup(start, stop, steps))
    # request all blocks from the store
    pendingBlocks = blockIdx.mapIt(
      self.store.getBlock(manifest[it]) # Get the data blocks (first K)
    )
    indices = pendingBlocks # needed so we can track the block indices
    iter = PendingBlocksIter(finished: false)

  trace "Requesting blocks", pendingBlocks = pendingBlocks.len
  proc next(): Future[?(bt.Block, int)] {.async.} =
    if iter.finished:
      trace "No more blocks"
      return none (bt.Block, int)

    if pendingBlocks.len == 0:
      iter.finished = true
      trace "No more blocks - finished"
      return none (bt.Block, int)

    let
      done = await one(pendingBlocks)
      idx = indices.find(done)

    logScope:
      idx = idx
      blockIdx = blockIdx[idx]
      manifest = manifest[blockIdx[idx]]

    pendingBlocks.del(pendingBlocks.find(done))
    without blk =? (await done), error:
      trace "Failed retrieving block", err = $error.msg
      return none (bt.Block, int)

    trace "Retrieved block"
    some (blk, blockIdx[idx])

  iter.next = next
  success iter

proc prepareEncodingData(
  self: Erasure,
  encoded: Manifest,
  step: int,
  data: ref seq[seq[byte]],
  emptyBlock: seq[byte]): Future[?!int] {.async.} =
  ## Prepare data for encoding
  ##

  without pendingBlocksIter =?
    self.getPendingBlocks(
      encoded,
      step,
      encoded.rounded - 1, encoded.steps), err:
    trace "Unable to get pending blocks", error = err.msg
    return failure(err)

  var resolved = 0
  for blkFut in pendingBlocksIter:
    if (blk, idx) =? (await blkFut):
      let
        pos = self.indexToPos(encoded, idx, step)

      if blk.isEmpty:
        trace "Padding with empty block", idx
        shallowCopy(data[pos], emptyBlock)
      else:
        trace "Encoding block", cid = blk.cid, idx
        shallowCopy(data[pos], blk.data)

      resolved.inc()

  success resolved

proc prepareDecodingData(
  self: Erasure,
  encoded: Manifest,
  step: int,
  data: ref seq[seq[byte]],
  parityData: ref seq[seq[byte]],
  emptyBlock: seq[byte]): Future[?!(int, int)] {.async.} =
  ## Prepare data for decoding
  ## `encoded`    - the encoded manifest
  ## `step`       - the current step
  ## `data`       - the data to be prepared
  ## `parityData` - the parityData to be prepared
  ## `emptyBlock` - the empty block to be used for padding
  ##

  without pendingBlocksIter =?
    self.getPendingBlocks(
      encoded,
      step,
      encoded.len - 1, encoded.steps), err:
      trace "Unable to get pending blocks", error = err.msg
      return failure(err)

  var
    dataPieces = 0
    parityPieces = 0
    resolved = 0
  for blkFut in pendingBlocksIter:
    # Continue to receive blocks until we have just enough for decoding
    # or no more blocks can arrive
    if resolved >= encoded.ecK:
      break

    if (blk, idx) =? (await blkFut):
      let
        pos = self.indexToPos(encoded, idx, step)

      logScope:
        cid   = blk.cid
        idx   = idx
        pos   = pos
        step  = step
        empty = blk.isEmpty

      if idx >= encoded.rounded:
        trace "Retrieved parity block"
        shallowCopy(parityData[pos - encoded.ecK], if blk.isEmpty: emptyBlock else: blk.data)
        parityPieces.inc
      else:
        trace "Retrieved data block"
        shallowCopy(data[pos], if blk.isEmpty: emptyBlock else: blk.data)
        dataPieces.inc

      resolved.inc

  return success (dataPieces, parityPieces)

proc prepareManifest(
  self: Erasure,
  manifest: Manifest,
  blocks: int,
  parity: int): ?!Manifest =

  logScope:
    original_cid = manifest.cid.get()
    original_len = manifest.len
    blocks       = blocks
    parity       = parity

  if blocks > manifest.len:
    trace "Unable to encode manifest, not enough blocks", blocks = blocks, len = manifest.len
    return failure("Not enough blocks to encode")

  trace "Preparing erasure coded manifest", blocks, parity
  without var encoded =? Manifest.new(manifest, blocks, parity), error:
    trace "Unable to create manifest", msg = error.msg
    return error.failure

  logScope:
    steps           = encoded.steps
    rounded_blocks  = encoded.rounded
    new_manifest    = encoded.len

  trace "Erasure coded manifest prepared"

  success encoded

proc encodeData(
  self: Erasure,
  manifest: Manifest): Future[?!void] {.async.} =
  ## Encode blocks pointed to by the protected manifest
  ##
  ## `manifest` - the manifest to encode
  ##

  var
    encoded = manifest

  logScope:
    steps           = encoded.steps
    rounded_blocks  = encoded.rounded
    new_manifest    = encoded.len
    protected       = encoded.protected
    ecK             = encoded.ecK
    ecM             = encoded.ecM

  if not encoded.protected:
    trace "Manifest is not erasure protected"
    return failure("Manifest is not erasure protected")

  var
    encoder = self.encoderProvider(encoded.blockSize.int, encoded.ecK, encoded.ecM)
    emptyBlock = newSeq[byte](encoded.blockSize.int)

  try:
    for step in 0..<encoded.steps:
      # TODO: Don't allocate a new seq every time, allocate once and zero out
      var
        data = seq[seq[byte]].new() # number of blocks to encode
        parityData = newSeqWith[seq[byte]](encoded.ecM, newSeq[byte](encoded.blockSize.int))

      data[].setLen(encoded.ecK)
      # TODO: this is a tight blocking loop so we sleep here to allow
      # other events to be processed, this should be addressed
      # by threading
      await sleepAsync(10.millis)

      without resolved =?
        (await self.prepareEncodingData(encoded, step, data, emptyBlock)), err:
          trace "Unable to prepare data", error = err.msg
          return failure(err)

      trace "Erasure coding data", data = data[].len, parity = parityData.len

      if (
        let res = encoder.encode(data[], parityData);
        res.isErr):
        trace "Unable to encode manifest!", error = $res.error
        return res.mapFailure

      var idx = encoded.rounded + step
      for j in 0..<encoded.ecM:
        without blk =? bt.Block.new(parityData[j]), error:
          trace "Unable to create parity block", err = error.msg
          return failure(error)

        trace "Adding parity block", cid = blk.cid, idx
        encoded[idx] = blk.cid
        if isErr (await self.store.putBlock(blk)):
          trace "Unable to store block!", cid = blk.cid
          return failure("Unable to store block!")
        idx.inc(encoded.steps)
  except CancelledError as exc:
    trace "Erasure coding encoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding encoding error", exc = exc.msg
    return failure(exc)
  finally:
    encoder.release()

  return success()

proc encode*(
  self: Erasure,
  manifest: Manifest,
  blocks: int,
  parity: int): Future[?!Manifest] {.async.} =
  ## Encode a manifest into one that is erasure protected.
  ##
  ## `manifest`   - the original manifest to be encoded
  ## `blocks`     - the number of blocks to be encoded - K
  ## `parity`     - the number of parity blocks to generate - M
  ##

  without var encoded =? self.prepareManifest(manifest, blocks, parity), error:
    trace "Unable to prepare manifest", error = error.msg
    return failure error

  if err =? (await self.encodeData(encoded)).errorOption:
    trace "Unable to encode data", error = err.msg
    return failure err

  return success encoded

proc decode*(
  self: Erasure,
  encoded: Manifest,
  all = true): Future[?!Manifest] {.async.} =
  ## Decode a protected manifest into it's original
  ## manifest
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be recovered
  ## `all`     - if true, all blocks will be recovered,
  ##             including parity
  ##

  logScope:
    steps           = encoded.steps
    rounded_blocks  = encoded.rounded
    new_manifest    = encoded.len
    protected       = encoded.protected
    ecK             = encoded.ecK
    ecM             = encoded.ecM

  if not encoded.protected:
    trace "Manifest is not erasure protected"
    return failure "Manifest is not erasure protected"

  var
    decoder = self.decoderProvider(encoded.blockSize.int, encoded.ecK, encoded.ecM)
    emptyBlock = newSeq[byte](encoded.blockSize.int)
    hasParity = false

  trace "Decoding erasure coded manifest"
  try:
    for step in 0..<encoded.steps:
      # TODO: this is a tight blocking loop so we sleep here to allow
      # other events to be processed, this should be addressed
      # by threading
      await sleepAsync(10.millis)

      var
        data = seq[seq[byte]].new()
        # newSeq[seq[byte]](encoded.ecK) # number of blocks to encode
        parityData = seq[seq[byte]].new()
        recovered = newSeqWith[seq[byte]](encoded.ecK, newSeq[byte](encoded.blockSize.int))
        resolved = 0

      data[].setLen(encoded.ecK)        # set len to K
      parityData[].setLen(encoded.ecM)  # set len to M

      without (dataPieces, parityPieces) =?
        (await self.prepareDecodingData(encoded, step, data, parityData, emptyBlock)), err:
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
        if data[i].len <= 0 and not encoded.blocks[i].isEmpty:
          without blk =? bt.Block.new(recovered[i]), error:
            trace "Unable to create block!", exc = error.msg
            return failure(error)

          doAssert blk.cid in encoded.blocks,
            "Recovered block not in original manifest"

          trace "Recovered block", cid = blk.cid, index = i
          if isErr (await self.store.putBlock(blk)):
            trace "Unable to store block!", cid = blk.cid
            return failure("Unable to store block!")
  except CancelledError as exc:
    trace "Erasure coding decoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding decoding error", exc = exc.msg
    return failure(exc)
  finally:
    decoder.release()

  without decoded =? Manifest.new(blocks = encoded.blocks[0..<encoded.originalLen]), error:
    return error.failure

  return decoded.success

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
