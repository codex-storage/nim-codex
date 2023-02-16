## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/codex/blocktype as bt

import codex/stores/repostore

type
  MockRepoStore* = ref object of RepoStore
    delBlockCids*: seq[Cid]
    getBeMaxNumber*: int
    getBeOffset*: int

    testBlockExpirations*: seq[BlockExpiration]
    index: int

proc new*(T: type MockRepoStore): T =
  T(
    index: 0
  )

method delBlock*(self: MockRepoStore, cid: Cid): Future[?!void] =
  self.delBlockCids.add(cid)

method getBlockExpirations*(self: MockRepoStore, maxNumber: int, offset: int): Future[?!BlockExpirationIter] {.async.} =
  self.getBeMaxNumber = maxNumber
  self.getBeOffset = offset

  self.index = 0
  var iter = BlockExpirationIter()
  iter.finished = false

  proc next(): Future[?BlockExpiration] {.async.} =
    if self.index >= 0 and self.index < len(self.testBlockExpirations):
      let selectedBlock = self.testBlockExpirations[self.index]
      inc self.index
      iter.finished = self.index >= len(self.testBlockExpirations)
      return selectedBlock.some
    return BlockExpiration.none

  iter.next = next
  return success iter
