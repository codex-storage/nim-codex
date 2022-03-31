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
  trace "Erasure coding manifest", cid = manifest.cid.get(), len = manifest.len, blocks, parity

  let
    # total number of blocks to encode + padding blocks
    roundedBlocks = manifest.len + (blocks - (manifest.len mod blocks))
    blocksPerRow = roundedBlocks div blocks # number of blocks per row

  var
    encodedBlocks = newSeq[Cid](roundedBlocks + (blocksPerRow * parity))

  # copy original manifest blocks
  for i, b in manifest:
    encodedBlocks[i] = b

  var
    encoder = self.encoderProvider(blockSize, blocks, parity)

  try:
    for i in 0..<blocksPerRow:
      var
        data = newSeqOfCap[seq[byte]](blocks) # number of blocks to encode
        parityData = newSeqOfCap[seq[byte]](parity)

      var
        idx = i
        count = 0

      while count < blocks:
        idx.inc(blocksPerRow)
        count.inc()

        if idx < manifest.len:
          without var blk =? (await store.getBlock(encodedBlocks[idx])), error:
            trace "Unable to retrieve block", msg = error.msg
            return error.failure
          data.add(blk.data)
        else:
          data.add(newSeq[byte](blockSize)) # empty seq of size

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

        encodedBlocks[idx] = blk.cid
        if not (await store.putBlock(blk)):
          return failure("Unable to store block!")

        idx.inc(blocksPerRow)
        count.inc()
  finally:
    encoder.release()

  trace "New manifest will contain", blocks = encodedBlocks.len, blocksPerRow
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
