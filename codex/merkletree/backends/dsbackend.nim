## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ./merklestore
import pkg/datastore
import ../../namespaces

type
  DataStoreBackend* = ref object of MerkleStore
    store*: Datastore

method put*(
  self: DataStoreBackend,
  index, level: Natural,
  hash: seq[byte]): Future[?!void] {.async.} =
  success await self.store.put(index, hash)

method get*(self: DataStoreBackend, index, level: Natural): Future[!?seq[byte]] =
  raiseAssert("Not implemented!")

func new*(_: type DataStoreBackend, store: Datastore): DataStoreBackend =
  DataStoreBackend(store: store)
