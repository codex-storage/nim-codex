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
import pkg/codex/utils/safeasynciter

type MockRepoStore* = ref object of RepoStore
  delBlockCids*: seq[Cid]
  getBeMaxNumber*: int
  getBeOffset*: int

  testBlockExpirations*: seq[BlockExpiration]

method delBlock*(
    self: MockRepoStore, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  self.delBlockCids.add(cid)
  self.testBlockExpirations = self.testBlockExpirations.filterIt(it.cid != cid)
  return success()

method getBlockExpirations*(
    self: MockRepoStore, maxNumber: int, offset: int
): Future[?!SafeAsyncIter[BlockExpiration]] {.async: (raises: [CancelledError]).} =
  self.getBeMaxNumber = maxNumber
  self.getBeOffset = offset

  let
    testBlockExpirationsCpy = @(self.testBlockExpirations)
    limit = min(offset + maxNumber, len(testBlockExpirationsCpy))

  let
    iter1 = SafeAsyncIter[int].new(offset ..< limit)
    iter2 = map[int, BlockExpiration](
      iter1,
      proc(i: ?!int): Future[?!BlockExpiration] {.async: (raises: [CancelledError]).} =
        if i =? i:
          return success(testBlockExpirationsCpy[i])
        return failure("Unexpected error!"),
    )

  success(iter2)
