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

method size*(self: StoreStream): int =
  self.manifest.len * self.manifest.blockSize

method readOnce*(
  self: StoreStream,
  pbytes: pointer,
  nbytes: int): Future[int] {.async.} =

  if self.atEof:
    raise newLPStreamEOFError()

  var
    read = 0

  trace "Reading from manifest", cid = self.manifest.cid.get(), blocks = self.manifest.len
  while read < nbytes and not self.atEof:
    let
      pos = self.offset div self.manifest.blockSize
      blk = (await self.store.getBlock(self.manifest[pos])).tryGet()

      blockOffset =
        if self.offset >= self.manifest.blockSize:
          self.offset mod self.manifest.blockSize
        else:
          self.offset

      readBytes =
        if (nbytes - read) >= (self.manifest.blockSize - blockOffset):
          self.manifest.blockSize - blockOffset
        else:
          min(nbytes - read, self.manifest.blockSize)

    trace "Reading bytes from store stream", pos, cid = blk.cid, bytes = readBytes, blockOffset = blockOffset
    copyMem(
      pbytes.offset(read),
      if blk.isEmpty:
          self.emptyBlock[blockOffset].addr
        else:
          blk.data[blockOffset].addr,
      readBytes)

    self.offset += readBytes
    read += readBytes

  return read

method atEof*(self: StoreStream): bool =
  self.offset >= self.manifest.len * self.manifest.blockSize

method closeImpl*(self: StoreStream) {.async.} =
  try:
    trace "Closing StoreStream"
    self.offset = self.manifest.len * self.manifest.blockSize # set Eof
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Error closing StoreStream", msg = exc.msg

  await procCall LPStream(self).closeImpl()
