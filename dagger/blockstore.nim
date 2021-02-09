## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ./blocktype

export blocktype

type
  BlocksChangeHandler* = proc(blocks: seq[Block]) {.gcsafe, closure.}

  BlockProvider* = ref object of RootObj

  BlockStore* = object of BlockProvider
    changeHandlers: seq[BlocksChangeHandler]
    providers: seq[BlockProvider]

method getBlock*(b: BlockProvider, cid: Cid): Future[Block] {.base.} =
  discard

proc addBlockChageHandler*(s: var BlockStore, handler: BlocksChangeHandler) =
  discard

proc removeBlockChageHandler*(s: var BlockStore, handler: BlocksChangeHandler) =
  discard

proc putBlock*(s: var BlockStore, cids: Block | seq[Block]) =
  ## Put a block to the blockstore
  ##

  discard

method getBlock*(b: BlockStore, cid: Cid): Future[Block] =
  ## Get a block from block providers
  ##

  discard

proc delBlock*(s: var BlockStore, cids: Cid | seq[Cid]) =
  ## delete a block/s from the block store
  ##

  discard

proc hasBlock*(s: BlockStore, cid: Cid): bool =
  ## check if the block exists in the blockstore
  ##

  discard
