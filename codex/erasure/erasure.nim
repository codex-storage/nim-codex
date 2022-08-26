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

import pkg/chronos
import pkg/chronicles

import ../manifest
import ../stores
import ../errors
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

  logScope:
    original_cid = manifest.cid.get()
    original_len = manifest.len
    blocks       = blocks
    parity       = parity

  trace "Erasure coding manifest", blocks, parity
  without var encoded =? Manifest.new(manifest, blocks, parity), error:
    trace "Unable to create manifest", msg = error.msg
    return error.failure

  logScope:
    steps           = encoded.steps
    rounded_blocks  = encoded.rounded
    new_manifest    = encoded.len

  var
    encoder = self.encoderProvider(manifest.blockSize, blocks, parity)

  try:
    for i in 0..<encoded.steps:
      # TODO: Don't allocate a new seq every time, allocate once and zero out
      var
        data = newSeq[seq[byte]](blocks) # number of blocks to encode
        parityData = newSeqWith[seq[byte]](parity, newSeq[byte](manifest.blockSize))
        # calculate block indexes to retrieve
        blockIdx = toSeq(countup(i, encoded.rounded - 1, encoded.steps))
        # request all blocks from the store
        dataBlocks = await allFinished(
          blockIdx.mapIt( self.store.getBlock(encoded[it]) ))

      # TODO: this is a tight blocking loop so we sleep here to allow
      # other events to be processed, this should be addressed
      # by threading
      await sleepAsync(100.millis)

      for j in 0..<blocks:
        let idx = blockIdx[j]
        if idx < manifest.len:
          without blk =? (await dataBlocks[j]), error:
            trace "Unable to retrieve block", error = error.msg
            return failure error

          trace "Encoding block", cid = blk.cid, pos = idx
          shallowCopy(data[j], blk.data)
        else:
          trace "Padding with empty block", pos = idx
          data[j] = newSeq[byte](manifest.blockSize)

      trace "Erasure coding data", data = data.len, parity = parityData.len

      let res = encoder.encode(data, parityData);
      if res.isErr:
        trace "Unable to encode manifest!", error = $res.error
        return failure($res.error)

      for j in 0..<parity:
        let idx = encoded.rounded + blockIdx[j]
        without blk =? bt.Block.new(parityData[j]), error:
          trace "Unable to create parity block", err = error.msg
          return failure(error)

        trace "Adding parity block", cid = blk.cid, pos = idx
        encoded[idx] = blk.cid
        if isErr (await self.store.putBlock(blk)):
          trace "Unable to store block!", cid = blk.cid
          return failure("Unable to store block!")
  except CancelledError as exc:
    trace "Erasure coding encoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding encoding error", exc = exc.msg
    return failure(exc)
  finally:
    encoder.release()

  return encoded.success

proc decode*(
  self: Erasure,
  encoded: Manifest): Future[?!Manifest] {.async.} =
  ## Decode a protected manifest into its original manifest
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be recovered
  ##

  logScope:
    steps           = encoded.steps
    rounded_blocks  = encoded.rounded
    new_manifest    = encoded.len

  var
    decoder = self.decoderProvider(encoded.blockSize, encoded.K, encoded.M)

  try:
    for i in 0..<encoded.steps:
      # TODO: Don't allocate a new seq every time, allocate once and zero out
      let
        # calculate block indexes to retrieve
        blockIdx = toSeq(countup(i, encoded.len - 1, encoded.steps))
        # request all blocks from the store
        pendingBlocks = blockIdx.mapIt(
            self.store.getBlock(encoded[it]) # Get the data blocks (first K)
        )

      # TODO: this is a tight blocking loop so we sleep here to allow
      # other events to be processed, this should be addressed
      # by threading
      await sleepAsync(10.millis)

      var
        data = newSeq[seq[byte]](encoded.K) # number of blocks to encode
        parityData = newSeq[seq[byte]](encoded.M)
        recovered = newSeqWith[seq[byte]](encoded.K, newSeq[byte](encoded.blockSize))
        idxPendingBlocks = pendingBlocks # copy futures to make using with `one` easier
        emptyBlock = newSeq[byte](encoded.blockSize)
        resolved = 0

      while true:
        # Continue to receive blocks until we have just enough for decoding
        # or no more blocks can arrive
        if (resolved >= encoded.K) or (idxPendingBlocks.len == 0):
          break

        let
          done = await one(idxPendingBlocks)
          idx = pendingBlocks.find(done)

        idxPendingBlocks.del(idxPendingBlocks.find(done))

        without blk =? (await done), error:
          trace "Failed retrieving block", error = error.msg
          continue

        if idx >= encoded.K:
          trace "Retrieved parity block", cid = blk.cid, idx
          shallowCopy(parityData[idx - encoded.K], if blk.isEmpty: emptyBlock else: blk.data)
        else:
          trace "Retrieved data block", cid = blk.cid, idx
          shallowCopy(data[idx], if blk.isEmpty: emptyBlock else: blk.data)

        resolved.inc

      let
        dataPieces = data.filterIt( it.len > 0 ).len
        parityPieces = parityData.filterIt( it.len > 0 ).len

      if dataPieces >= encoded.K:
        trace "Retrieved all the required data blocks", data = dataPieces, parity = parityPieces
        continue

      trace "Erasure decoding data", data = dataPieces, parity = parityPieces
      if (
        let err = decoder.decode(data, parityData, recovered);
        err.isErr):
        trace "Unable to decode manifest!", err = $err.error
        return failure($err.error)

      for i in 0..<encoded.K:
        if data[i].len <= 0:
          without blk =? bt.Block.new(recovered[i]), error:
            trace "Unable to create block!", exc = error.msg
            return failure(error)

          trace "Recovered block", cid = blk.cid
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

  without decoded =? encoded.unprotect(blocks = encoded.blocks[0..<encoded.originalLen]), error:
    return failure error

  return success decoded

proc start*(self: Erasure) {.async.} =
  return

proc stop*(self: Erasure) {.async.} =
  return

proc new*(
  T: type Erasure,
  store: BlockStore,
  encoderProvider: EncoderProvider,
  decoderProvider: DecoderProvider): Erasure =

  Erasure(
    store: store,
    encoderProvider: encoderProvider,
    decoderProvider: decoderProvider)
