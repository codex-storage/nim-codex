## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/chronicles

import ../manifest
import ../stores
import ../errors

import ./backend

export backend

logScope:
  topics = "dagger erasure"

type
  EncoderProvider* = proc(size, blocks, parity: int): EncoderBackend
    {.raises: [Defect], noSideEffect.}

  DecoderProvider* = proc(size, blocks, parity: int): DecoderBackend
    {.raises: [Defect], noSideEffect.}

  Erasure* = ref object
    encoderProvider*: EncoderProvider
    decoderProvider*: DecoderProvider

proc encode*(
  self: Erasure,
  manifest: Manifest,
  store: BlockStore,
  blocks: int,
  parity: int,
  blockSize = BlockSize): Future[?!Manifest] {.async.} =
  ## Encode a manifest into a manifest that is erasure
  ## protected.
  ##
  ## The new manifest has a matrix geometry where each
  ## `blocks` (K), are encoded into additional `parity`
  ## blocks (M). The resulting dataset is logically
  ## divided into rows where each column of K blocks is
  ## extended with M parity blocks.
  ##
  ## The encoding is systematic and the rows can be
  ## read sequentially by any node without decoding.
  ## Decoding is possible with any combination of
  ## K rows or partial K columns or any combination
  ## there of.
  ##
  ## NOTE: The resulting dataset might be padded with extra
  ## blocks. This is blocks might be eventually excluded
  ## from transmission, but they aren't right now.
  ##
  ## `manifest`   - the original manifest to be encoded
  ## `store`      - the blocks store used to retrieve blocks
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

  let
    # total number of blocks to encode + padding blocks
    roundedBlocks =
      if (manifest.len mod blocks) != 0:
        manifest.len + (blocks - (manifest.len mod blocks))
      else:
        manifest.len
    steps = roundedBlocks div blocks # number of blocks per row
    manifestLen = roundedBlocks + (steps * parity)

  logScope:
    steps           = steps
    new_blocks      = roundedBlocks
    new_manifest    = manifestLen

  trace "New dataset geometry is"
  var
    encodedBlocks = newSeq[Cid](manifestLen)

  # copy original manifest blocks
  for i, b in manifest:
    encodedBlocks[i] = b

  var
    encoder = self.encoderProvider(blockSize, blocks, parity)

  try:
    for i in 0..<steps:
      var
        data = newSeqOfCap[seq[byte]](blocks) # number of blocks to encode
        parityData = newSeqOfCap[seq[byte]](parity)

      var
        idx = i
        count = 0

      while count < blocks:
        if idx < manifest.len:
          without var blk =? (await store.getBlock(encodedBlocks[idx])), error:
            trace "Unable to retrieve block", msg = error.msg
            return error.failure

          trace "Encoding block", cid = blk.cid, pos = idx
          data.add(blk.data)
        else:
          data.add(newSeq[byte](blockSize)) # empty seq of size

        idx.inc(steps)
        count.inc()

      for _ in 0..<parity:
        parityData.add(newSeq[byte](blockSize))

      if (let err = encoder.encode(data, parityData); err.isErr):
        trace "Unable to encode manifest!", err = $err.error
        return failure($err.error)

      count = 0
      while count < parity:
        without blk =? Block.new(parityData[count]), error:
          trace "Unable to create parity block", err = error.msg
          return failure(error)

        trace "Adding parity block", cid = blk.cid, pos = idx
        encodedBlocks[idx] = blk.cid
        if not (await store.putBlock(blk)):
          return failure("Unable to store block!")

        idx.inc(steps)
        count.inc()
  finally:
    encoder.release()

  trace "New manifest will contain"
  without var encoded =? Manifest.new(blocks = encodedBlocks), error:
    trace "Unable to create manifest", msg = error.msg
    return error.failure

  return encoded.success

proc decode*(
  self: Erasure,
  manifest: Manifest,
  store: BlockStore,
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
  encoderProvider: EncoderProvider,
  decoderProvider: DecoderProvider): Erasure =

  Erasure(
    encoderProvider: encoderProvider,
    decoderProvider: decoderProvider)
