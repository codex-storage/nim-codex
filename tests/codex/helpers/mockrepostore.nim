## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import pkg/codex/stores/repostore
import pkg/codex/utils/asynciter

type
  MockRepoStore* = ref object of RepoStore
    delBlockCids*: seq[Cid]
    getBeMaxNumber*: int
    getBeOffset*: int

    testBlockExpirations*: seq[BlockExpiration]
    getBlockExpirationsThrows*: bool
    iteratorIndex: int

method delBlock*(self: MockRepoStore, cid: Cid): Future[?!void] {.async.} =
  self.delBlockCids.add(cid)
  self.testBlockExpirations = self.testBlockExpirations.filterIt(it.cid != cid)
  dec self.iteratorIndex
  return success()

method getBlockExpirations*(self: MockRepoStore, maxNumber: int, offset: int): Future[?!AsyncIter[?BlockExpiration]] {.async.} =
  if self.getBlockExpirationsThrows:
    raise new CatchableError

  self.getBeMaxNumber = maxNumber
  self.getBeOffset = offset

  var iter = AsyncIter[?BlockExpiration]()
  iter.finished = false

  self.iteratorIndex = offset
  var numberLeft = maxNumber
  proc next(): Future[?BlockExpiration] {.async.} =
    if numberLeft > 0 and self.iteratorIndex >= 0 and self.iteratorIndex < len(self.testBlockExpirations):
      dec numberLeft
      let selectedBlock = self.testBlockExpirations[self.iteratorIndex]
      inc self.iteratorIndex
      return selectedBlock.some
    iter.finish
    return BlockExpiration.none

  iter.next = next
  return success iter
