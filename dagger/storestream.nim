## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/stew/ptrops

import ./stores
import ./manifest
import ./blocktype

export stores

logScope:
  topics = "dagger storestream"

type
  ReadPattern* {.pure.} = enum
    Sequential,
    Grid

  StoreStream* = ref object of LPStream
    store*: BlockStore
    manifest*: Manifest
    pattern*: ReadPattern
    offset*: int

proc init*(
  T: type StoreStream,
  store: BlockStore,
  manifest: Manifest,
  pattern = ReadPattern.Sequential): T =
  result = T(
    store: store,
    manifest: manifest,
    pattern: pattern,
    offset: 0)

  result.initStream()

method readOnce*(
  self: StoreStream,
  pbytes: pointer,
  nbytes: int): Future[int] {.async.} =

  if self.atEof:
    raise newLPStreamEOFError()

  var
    read = 0

  while read < nbytes and self.atEof.not:
    let
      pos = self.offset div self.manifest.blockSize

    let
      blk = (await self.store.getBlock(self.manifest[pos])).tryGet()
      blockOffset = if self.offset >= self.manifest.blockSize:
          self.offset mod self.manifest.blockSize
        else:
          self.offset

      readBytes = if (nbytes - read) >= (self.manifest.blockSize - blockOffset):
          self.manifest.blockSize - blockOffset
        else:
          min(nbytes - read, self.manifest.blockSize)

    copyMem(pbytes.offset(read), unsafeAddr blk.data[blockOffset], readBytes)
    self.offset += readBytes
    read += readBytes

  return read

method atEof*(self: StoreStream): bool =
  self.offset >= self.manifest.len * self.manifest.blockSize

method closeImpl*(self: StoreStream) {.async.} =
  try:
    trace "Closing StoreStream", self
    self.offset = self.manifest.len * self.manifest.blockSize # set Eof
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Error closing StoreStream", s, msg = exc.msg

  await procCall LPStream(self).closeImpl()
