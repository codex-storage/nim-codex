## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/chronicles
import pkg/asynctest

import codex/stores/blockstore
import codex/stores/maintenance

type
  MockBlockChecker* = ref object of BlockChecker
    expectedBlockStore: BlockStore
    checkCalls*: seq[Cid]

proc new*(T: type MockBlockChecker, expectedBlockStore: BlockStore): T =
  T(
    expectedBlockStore: expectedBlockStore,
    checkCalls: []
  )

method checkBlock(blockChecker: MockBlockChecker, blockStore: BlockStore, cid: Cid) =
  echo "mock logging checkBlock"
  check blockStore == blockChecker.expectedBlockStore
  blockChecker.checkCalls.add(cid)
