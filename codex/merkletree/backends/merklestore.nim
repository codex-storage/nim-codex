## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

type
  MerkleStore* = ref object of RootObj

method put*(self: MerkleStore, index, level: Natural, hash: seq[byte]): Future[?!void] =
  raiseAssert("Not implemented!")

method get*(self: MerkleStore, index, level: Natural): Future[!?seq[byte]] =
  raiseAssert("Not implemented!")
