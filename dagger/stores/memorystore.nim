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
import pkg/libp2p

import ../stores/blockstore
import ../blocktype

export blockstore

type
  MemoryStore* = ref object of BlockStore
    blocks: seq[Block] # TODO: Should be an LRU cache

method getBlocks*(
  s: MemoryStore,
  cids: seq[Cid]): Future[seq[Block]] {.async.} =
  ## Get a block from the stores
  ##

  var res: seq[Block]
  for c in cids:
    res.add(s.blocks.filterIt( it.cid == c ))

  return res

method hasBlock*(s: MemoryStore, cid: Cid): bool =
  ## check if the block exists
  ##

  s.blocks.filterIt( it.cid == cid ).len > 0

method putBlocks*(s: MemoryStore, blocks: seq[Block]) =
  ## Put a block to the blockstore
  ##

  s.blocks.add(blocks)
  procCall BlockStore(s).putBlocks(blocks)

method delBlocks*(s: MemoryStore, cids: seq[Cid]) =
  ## delete a block/s from the block store
  ##

  for c in cids:
    s.blocks.keepItIf( it.cid != c )

  procCall BlockStore(s).delBlocks(cids)

proc new*(T: type MemoryStore, blocks: openArray[Block] = []): MemoryStore =
  MemoryStore(
    blocks: @blocks
  )
