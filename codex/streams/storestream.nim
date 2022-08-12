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

import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/stew/ptrops

import ../stores
import ../manifest
import ../blocktype

import ./seekablestream

export stores, blocktype, manifest, chronos

logScope:
  topics = "dagger storestream"

type
  StoreStream* = ref object of SeekableStream
    store*: BlockStore
    manifest*: Manifest
    emptyBlock*: seq[byte]

proc new*(
  T: type StoreStream,
  store: BlockStore,
  manifest: Manifest): T =
  result = T(
    store: store,
    manifest: manifest,
    offset: 0,
    emptyBlock: newSeq[byte](manifest.blockSize))

  result.initStream()

method `size`*(self: StoreStream): int =
  self.manifest.len * self.manifest.blockSize

proc `size=`*(self: StoreStream, size: int)
  {.error: "Setting the size is forbidden".} =
  discard

method atEof*(self: StoreStream): bool =
  self.offset >= self.size

method readOnce*(
  self: StoreStream,
  pbytes: pointer,
  nbytes: int): Future[int] {.async.} =
  ## Read `nbytes` from current position in the StoreStream into output buffer pointed by `pbytes`.
  ## Return how many bytes were actually read before EOF was encountered.
  ## Raise exception if we are already at EOF.

  trace "Reading from manifest", cid = self.manifest.cid.get(), blocks = self.manifest.len
  if self.atEof:
    raise newLPStreamEOFError()

  # The loop iterates over blocks in the StoreStream,
  # reading them and copying their data into outbuf
  var read = 0  # Bytes read so far, and thus write offset in the outbuf
  while read < nbytes and not self.atEof:
    # Compute from the current stream position `self.offset` the block num/offset to read
    # Compute how many bytes to read from this block
    let
      blockNum    = self.offset div self.manifest.blockSize
      blockOffset = self.offset mod self.manifest.blockSize
      readBytes   = min(nbytes - read, self.manifest.blockSize - blockOffset)

    # Read contents of block `blockNum`
    let
      getRes = await self.store.getBlock(self.manifest[blockNum])

    if getRes.isErr: raise newLPStreamReadError(getRes.error)

    let
      blk = getRes.get

    trace "Reading bytes from store stream", blockNum, cid = blk.cid, bytes = readBytes, blockOffset

    # Copy `readBytes` bytes starting at `blockOffset` from the block into the outbuf
    copyMem(
      pbytes.offset(read),
      if blk.isEmpty:
          self.emptyBlock[blockOffset].addr
        else:
          blk.data[blockOffset].addr,
      readBytes)

    # Update current positions in the stream and outbuf
    self.offset += readBytes
    read += readBytes

  return read

method closeImpl*(self: StoreStream) {.async.} =
  try:
    trace "Closing StoreStream"
    self.offset = self.manifest.len * self.manifest.blockSize # set Eof
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Error closing StoreStream", msg = exc.msg

  await procCall LPStream(self).closeImpl()
