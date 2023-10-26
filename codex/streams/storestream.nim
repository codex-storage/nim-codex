## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options

import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/chronicles
import pkg/stew/ptrops

import ../stores
import ../manifest
import ../blocktype
import ../utils

import ./seekablestream

export stores, blocktype, manifest, chronos

logScope:
  topics = "codex storestream"

const
  SeekableStoreStreamTrackerName* = "SeekableStoreStream"

type
  # Make SeekableStream from a sequence of blocks stored in Manifest
  # (only original file data - see StoreStream.size)
  SeekableStoreStream* = ref object of SeekableStream
    store*: BlockStore          # Store where to lookup block contents
    manifest*: Manifest         # List of block CIDs
    pad*: bool                  # Pad last block to manifest.blockSize?

method initStream*(s: SeekableStoreStream) =
  if s.objName.len == 0:
    s.objName = SeekableStoreStreamTrackerName

  procCall SeekableStream(s).initStream()

proc new*(
    T: type SeekableStoreStream,
    store: BlockStore,
    manifest: Manifest,
    pad = true
): SeekableStoreStream =
  ## Create a new SeekableStoreStream instance for a given store and manifest
  ## 
  result = SeekableStoreStream(
    store: store,
    manifest: manifest,
    pad: pad,
    offset: 0)

  result.initStream()

method `size`*(self: SeekableStoreStream): int =
  bytes(self.manifest, self.pad).int

proc `size=`*(self: SeekableStoreStream, size: int)
  {.error: "Setting the size is forbidden".} =
  discard

method atEof*(self: SeekableStoreStream): bool =
  self.offset >= self.size

method readOnce*(
    self: SeekableStoreStream,
    pbytes: pointer,
    nbytes: int
): Future[int] {.async.} =
  ## Read `nbytes` from current position in the SeekableStoreStream into output buffer pointed by `pbytes`.
  ## Return how many bytes were actually read before EOF was encountered.
  ## Raise exception if we are already at EOF.
  ## 

  trace "Reading from manifest", cid = self.manifest.cid.get(), blocks = self.manifest.blocksCount
  if self.atEof:
    raise newLPStreamEOFError()

  # The loop iterates over blocks in the SeekableStoreStream,
  # reading them and copying their data into outbuf
  var read = 0  # Bytes read so far, and thus write offset in the outbuf
  while read < nbytes and not self.atEof:
    # Compute from the current stream position `self.offset` the block num/offset to read
    # Compute how many bytes to read from this block
    let
      blockNum    = self.offset div self.manifest.blockSize.int
      blockOffset = self.offset mod self.manifest.blockSize.int
      readBytes   = min([self.size - self.offset,
                         nbytes - read,
                         self.manifest.blockSize.int - blockOffset])
      address     = BlockAddress(leaf: true, treeCid: self.manifest.treeCid, index: blockNum)

    # Read contents of block `blockNum`
    without blk =? await self.store.getBlock(address), error:
      raise newLPStreamReadError(error)

    trace "Reading bytes from store stream", blockNum, cid = blk.cid, bytes = readBytes, blockOffset

    # Copy `readBytes` bytes starting at `blockOffset` from the block into the outbuf
    if blk.isEmpty:
      zeroMem(pbytes.offset(read), readBytes)
    else:
      copyMem(pbytes.offset(read), blk.data[blockOffset].addr, readBytes)

    # Update current positions in the stream and outbuf
    self.offset += readBytes
    read += readBytes

  return read

method closeImpl*(self: SeekableStoreStream) {.async.} =
  trace "Closing SeekableStoreStream"
  self.offset = self.size  # set Eof
  await procCall LPStream(self).closeImpl()
