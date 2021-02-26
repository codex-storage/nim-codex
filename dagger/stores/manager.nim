## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronos
import ./blockstore

type
  BlockStoreManager* = ref object of BlockStore
    stores: seq[BlockStore]

proc addProvider*(b: BlockStoreManager, provider: BlockStore) =
  b.stores.add(provider)

proc removeProvider*(b: BlockStoreManager, provider: BlockStore) =
  b.stores.keepItIf( it != provider )

method addChangeHandler*(
  s: BlockStoreManager,
  handler: BlocksChangeHandler,
  changeType: ChangeType) =
  ## Add change handler to all registered
  ## block stores
  ##

  for p in s.stores:
    p.addChangeHandler(handler, changeType)

method removeChangeHandler*(
  s: BlockStoreManager,
  handler: BlocksChangeHandler,
  changeType: ChangeType) =
  ## Remove change handler from all registered
  ## block stores
  ##

  for p in s.stores:
    p.removeChangeHandler(handler, changeType)
