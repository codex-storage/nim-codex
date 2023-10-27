## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/questionable/results

type
  MerkleStore* = ref object of RootObj

method put*(self: MerkleStore, index: Natural, hash: seq[byte]): Future[?!void] {.base.} =
  ## Put the hash of the file at the given index and level.
  ##

  raiseAssert("Not implemented!")

method get*(self: MerkleStore, index: Natural): Future[?!seq[byte]] {.base.} =
  ## Get hash at index and level.
  raiseAssert("Not implemented!")

method seal*(self: MerkleStore, id: string = ""): Future[?!void] {.base.} =
  ## Perform misc tasks required to finish persisting the merkle tree.
  ##

  raiseAssert("Not implemented!")
