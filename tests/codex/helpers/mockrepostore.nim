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

    getBlockExpirationsThrows*: bool
    iteratorIndex: int

method delBlock*(self: MockRepoStore, cid: Cid): Future[?!void] {.async.} =
  self.delBlockCids.add(cid)
  dec self.iteratorIndex
  return success()
