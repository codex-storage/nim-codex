## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
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
  StoreStreamTrackerName* = "StoreStream"

type
  StoreStream* = ref object of LPStream
    store*: BlockStore          # Store where to lookup block contents
    manifest*: Manifest         # List of block CIDs
    pad*: bool                  # Pad last block to manifest.blockSize?
    iter: AsyncIter[?!Block]
    lastBlock: Block
    lastIndex: int
    offset: int

method initStream*(s: StoreStream) =
  if s.objName.len == 0:
    s.objName = StoreStreamTrackerName

  procCall LPStream(s).initStream()

proc new*(
    T: type StoreStream,
    store: BlockStore,
    manifest: Manifest,
    pad = true
): StoreStream =
  ## Create a new StoreStream instance for a given store and manifest
  ##
  result = StoreStream(
    store: store,
    manifest: manifest,
    pad: pad,
    lastIndex: -1,
    offset: 0)

  result.initStream()

method `size`*(self: StoreStream): int =
  bytes(self.manifest, self.pad).int

proc `size=`*(self: StoreStream, size: int)
  {.error: "Setting the size is forbidden".} =
  discard

method atEof*(self: StoreStream): bool =
  self.offset >= self.size

method readOnce*(
    self: StoreStream,
    pbytes: pointer,
    nbytes: int
): Future[int] {.async.} =
  ## Read `nbytes` from current position in the StoreStream into output buffer pointed by `pbytes`.
  ## Return how many bytes were actually read before EOF was encountered.
  ## Raise exception if we are already at EOF.
  ##

  trace "Reading from manifest", cid = self.manifest.cid.get(), blocks = self.manifest.blocksCount
  if self.atEof:
    raise newLPStreamEOFError()
  
  # Initialize a block iterator
  if self.lastIndex < 0:
    without iter =? await self.store.getBlocks(self.manifest.treeCid, self.manifest.blocksCount, self.manifest.treeRoot), err:
      raise newLPStreamReadError(err)
    self.iter = iter

  var read = 0  # Bytes read so far, and thus write offset in the outbuf
  while read < nbytes and not self.atEof:
    if self.offset >= (self.lastIndex + 1) * self.manifest.blockSize.int:
      if not self.iter.finished:
        without lastBlock =? await self.iter.next(), err:
          raise newLPStreamReadError(err)
        self.lastBlock = lastBlock
        inc self.lastIndex
      else:
        raise newLPStreamReadError(newException(CodexError, "Block iterator finished prematurely"))
    # Compute how many bytes to read from this block
    let
      blockOffset = self.offset mod self.manifest.blockSize.int
      readBytes   = min([self.size - self.offset,
                         nbytes - read,
                         self.manifest.blockSize.int - blockOffset])
    # Copy `readBytes` bytes starting at `blockOffset` from the block into the outbuf
    if self.lastBlock.isEmpty:
      zeroMem(pbytes.offset(read), readBytes)
    else:
      copyMem(pbytes.offset(read), self.lastBlock.data[blockOffset].addr, readBytes)

    # Update current positions in the stream and outbuf
    self.offset += readBytes
    read += readBytes

  return read

method closeImpl*(self: StoreStream) {.async.} =
  trace "Closing StoreStream"
  self.offset = self.size  # set Eof
  await procCall LPStream(self).closeImpl()
