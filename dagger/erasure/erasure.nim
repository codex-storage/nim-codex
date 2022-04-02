## Nim-Dagger
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
import ../blocktype

import ./backend

export backend

logScope:
  topics = "dagger erasure"

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
  parity: int,
  blockSize = BlockSize): Future[?!Manifest] {.async.} =
  ## Encode a manifest into one that is erasure protected.
  ##
  ## `manifest`   - the original manifest to be encoded
  ## `blocks`     - the number of blocks to be encoded - K
  ## `parity`     - the number of parity blocks to generate - M
  ## `blockSize`  - size of each individual blocks - all blocks
  ##                should have equal size
  ##

  logScope:
    original_cid = manifest.cid.get()
    original_len = manifest.len
    blocks       = blocks
    parity       = parity

  trace "Erasure coding manifest", blocks, parity

  trace "New dataset geometry is"
  without var encoded =? Manifest.new(manifest, blocks, parity), error:
    trace "Unable to create manifest", msg = error.msg
    return error.failure

  logScope:
    steps           = encoded.steps
    new_blocks      = encoded.rounded
    new_manifest    = encoded.len

  var
    encoder = self.encoderProvider(blockSize, blocks, parity)

  try:
    for i in 0..<encoded.steps:
      # TODO: Don't allocate a new seq everytime, allocate once and zero out
      var
        data = newSeq[seq[byte]](blocks) # number of blocks to encode
        parityData = newSeqWith[seq[byte]](parity, newSeq[byte](blockSize))
        # calculate block indexes to retrieve
        blockIdx = toSeq(countup(i, encoded.rounded - 1, encoded.steps))
        # request all blocks from the store
        dataBlocks = await allFinished(
          blockIdx.mapIt( self.store.getBlock(encoded[it]) ))

      for j in 0..<blocks:
        let idx = blockIdx[j]
        if idx < (manifest.len - 1):
          without var blk =? await dataBlocks[j], error:
            trace "Unable to retrieve block", msg = error.msg
            return error.failure

          trace "Encoding block", cid = blk.cid, pos = idx
          shallowCopy(data[j], blk.data)
        else:
          trace "Padding with empty block", pos = idx
          data[j] = newSeq[byte](blockSize)

      if (let err = encoder.encode(data, parityData); err.isErr):
        trace "Unable to encode manifest!", err = $err.error
        return failure($err.error)

      for j in 0..<parity:
        let idx = encoded.rounded + i
        without blk =? Block.new(parityData[j]), error:
          trace "Unable to create parity block", err = error.msg
          return failure(error)

        trace "Adding parity block", cid = blk.cid, pos = idx
        encoded[idx] = blk.cid
        if not (await self.store.putBlock(blk)):
          trace "Unable to store block!", cid = blk.cid
          return failure("Unable to store block!")
  except CancelledError as exc:
    trace "Erasure coding encoding cancelled"
    raise exc
  except CatchableError as exc:
    trace "Erasure coding error", exc = exc.msg
    return failure(exc)
  finally:
    encoder.release()

  return encoded.success

proc decode*(
  self: Erasure,
  manifest: Manifest,
  blocks: int,
  parity: int,
  blockSize = BlockSize): Future[?!Manifest] {.async.} =
  var
    decoder = self.decoderProvider(blockSize, blocks, parity)

  without var decoded =? Manifest.new(), error:
    return error.failure

  try:
    # decoder.decode()
    discard
  finally:
    decoder.release()

  return decoded.success

proc start*(self: Erasure) {.async.} =
  discard

proc stop*(self: Erasure) {.async.} =
  discard

proc new*(
  T: type Erasure,
  store: BlockStore,
  encoderProvider: EncoderProvider,
  decoderProvider: DecoderProvider): Erasure =

  Erasure(
    store: store,
    encoderProvider: encoderProvider,
    decoderProvider: decoderProvider)
