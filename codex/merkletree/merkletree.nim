## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/math
import std/bitops
import std/sequtils
import std/sugar
import std/algorithm

import pkg/upraises
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/nimcrypto/sha2
import pkg/libp2p/[cid, multicodec, multihash, vbuffer]
import pkg/stew/byteutils

import ../errors
import ../utils

import ./merklestore

logScope:
  topics = "codex merkletree"

type
  MerkleTree* = ref object of RootObj
    root*: ?MultiHash               # the root hash of the tree
    mcodec: MultiCodec              # multicodec of the hash function
    height: Natural                 # current height of the tree (levels - 1)
    levels: Natural                 # number of levels in the tree (height + 1)
    leafs: Natural                  # total number of leafs, if odd the last leaf will be hashed twice
    length: Natural                 # corrected to even number of leafs in the tree
    size: Natural                   # total number of nodes in the tree (corrected for odd leafs)
    store: MerkleStore              # store for the tree
    leafsIter: AsyncIter[seq[byte]] # leafs iterator of the tree

  MerkleProof* = object
    mcodec: MultiCodec
    index: Natural
    nodes*: seq[seq[byte]]

###########################################################
# MerkleTree
###########################################################

proc build*(self: MerkleTree): Future[?!void] {.async.} =
  ## Builds a tree from leafs
  ##

  var length = self.length
  while length > 1:
    for i in 0..<length div 2:
      echo i
      if self.leafsIter.finished:
        return failure("Not enough leafs")

      let
        left = await self.leafsIter.next()
        right = await self.leafsIter.next()

      without hash =?
        MultiHash.digest($self.mcodec, left & right).mapFailure, err:
          return failure(err)

      let index = self.length + length + i
      (await self.store.put(index, hash.bytes)).tryGet

    length = length shr 1

  without root =? (await self.store.get(self.size)) and
    rootHash =? MultiHash.digest($self.mcodec, root).mapFailure, err:
    return failure "Unable to get tree root"

  self.root = rootHash.some
  return success()

proc getProofs(
  self: MerkleTree,
  indexes: openArray[Natural]): Future[?!seq[MerkleProof]] {.async.} =
  ## Returns a proof for the given index
  ##

  var
    proofs = newSeq[MerkleProof]()

  for idx in indexes:
    var
      index = idx
      nodes: seq[seq[byte]]

    without node =? (await self.store.get(index)):
      return failure "Unable to get node"

    nodes.add(node)

    for level in 1..<self.levels:
      debugEcho level
      let
        idx = if bool(index and 1):
          level + 1
        else:
          level - 1

      without node =? (await self.store.get(idx)), err:
        return failure "Unable to get node"

      nodes.add(node)
      index = index shr 1

    proofs.add(
      MerkleProof(
        mcodec: self.mcodec,
        index: index,
        nodes: nodes))

  return success proofs

func new*(
  T: type MerkleTree,
  store: MerkleStore,
  leafs: Natural,
  leafsIter: AsyncIter[seq[byte]],
  mcodec: MultiCodec = multiCodec("sha2-256")): ?!MerkleTree =
  ## Init empty tree with capacity `leafs`
  ##

  let
    maxWidth = nextPowerOfTwo(leafs)
    length = if bool(leafs and 1): leafs + 1 else: leafs
    size = 2 * length
    height = log2(maxWidth.float).Natural
    self = MerkleTree(
      store: store,
      mcodec: mcodec,
      leafs: leafs,
      length: length,
      size: size,
      height: height,
      levels: height - 1,
      leafsIter: leafsIter)

  success self

when isMainModule:
  import std/os
  import std/sequtils

  import pkg/chronos
  import pkg/stew/byteutils
  import pkg/questionable
  import pkg/questionable/results

  proc main() {.async.} =
    var
      leafs = [
        "A", "B", "C", "D", "E", "F",
        "G", "H", "I", "J", "K", "L",
        "M", "N", "O", "P"]
        .mapIt(
          MultiHash.digest("sha2-256", it.toBytes).tryGet().data.buffer
        )

    let
      file = open("tmp.merkle" , fmReadWrite)
      store = FileStore.new(file, os.getCurrentDir()).tryGet()
      tree = MerkleTree.new(
        store = store,
        leafs.len,
        Iter.fromSlice(0..<leafs.len)
        .map(
          proc(i: int): Future[seq[byte]] {.async.} =
            leafs[i])).tryGet()

    (await tree.build()).tryGet
    # echo tree.root.get()

    # echo (await tree.getProofs(@[0.Natural, 1, 2, 3, 4, 5])).tryGet

  waitFor main()
