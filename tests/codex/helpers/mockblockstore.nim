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

import codex/stores/blockstore

type
  MockBlockStore* = ref object of BlockStore

method getBlock*(self: MockBlockStore, cid: Cid): Future[?!Block] =
  raiseAssert("Not implemented!")

method delBlock*(self: MockBlockStore, cid: Cid): Future[?!void] =
  raiseAssert("Not implemented!")

method listBlocks*(
  self: MockBlockStore,
  blockType = BlockType.Manifest): Future[?!BlocksIter] =
  raiseAssert("Not implemented!")

