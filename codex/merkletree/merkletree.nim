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

import pkg/chronicles
import pkg/questionable/results
import pkg/nimcrypto/sha2
import pkg/libp2p/[cid, multicodec, multihash, vbuffer]
import pkg/stew/byteutils

import ../errors

logScope:
  topics = "codex merkletree"

type
  MerkleTree* = object
    mcodec: MultiCodec      # multicodec of the hash function
    maxWidth: Natural       # max width of the tree
    height: Natural         # current height of the tree (levels - 1)
    levels: Natural         # number of levels in the tree (height + 1)
    leafs: Natural          # total number of leafs, if odd the last leaf will be hashed twice
    nodes: seq[seq[byte]]   # nodes of the tree (this should be an iterator)

  MerkleProof* = object
    mcodec: MultiCodec
    index: Natural
    nodes*: seq[seq[byte]]

###########################################################
# MerkleTree
###########################################################

proc root*(self: MerkleTree): ?!MultiHash =
  echo self.nodes.len
  if self.nodes.len == 0 or self.nodes[^1].len == 0:
    return failure("Tree hasn't been build")

  MultiHash.init(self.mcodec, self.nodes[^1]).mapFailure

proc init*(
  T: type MerkleTree,
  leafs: Natural,
  mcodec: MultiCodec = multiCodec("sha2-256")): ?!MerkleTree =
  ## Init empty tree with capacity `leafs`
  ##

  let
    maxWidth = nextPowerOfTwo(leafs)
    size = 2 * leafs
    height = log2(size.float).Natural
    self = MerkleTree(
      mcodec: mcodec,
      maxWidth: maxWidth,
      leafs: leafs,
      height: height,
      levels: height - 1,
      nodes: newSeq[seq[byte]](size))

  success self

proc init*(
  T: type MerkleTree,
  leafs: openArray[seq[byte]],
  mcodec: MultiCodec = multiCodec("sha2-256")): ?!MerkleTree =
  ## Init tree from vector of leafs
  ##

  var
    self = ? MerkleTree.init(leafs.len, mcodec)

  self.nodes[0..<self.leafs] = leafs.toOpenArray(0, leafs.high)

  success self

proc buildSync*(self: var MerkleTree): ?!void =
  ## Builds a tree from previously added data blocks
  ##
  ## Tree built from data blocks A, B and C is
  ##        H5=H(H3 & H4)
  ##      /            \
  ##    H3=H(H0 & H1)   H4=H(H2 & 0x00)
  ##   /    \          /
  ## H0=H(A) H1=H(B) H2=H(C)
  ## |       |       |
  ## A       B       C
  ##
  ## Memory layout is [H0, H1, H2, H3, H4, H5]
  ##

  var
    length = if bool(self.leafs and 1):
      self.nodes[self.leafs] = self.nodes[self.leafs - 1] # even out the tree
      self.leafs + 1
    else:
      self.leafs

  while length > 1:
    for i in 0..<length:
      let
        left = self.nodes[i * 2]
        right = self.nodes[i * 2 + 1]
        hash = ? MultiHash.digest($self.mcodec, left & right).mapFailure

      self.nodes[length + i] = hash.data.buffer

    length = length shr 2

  echo self.nodes
  return success()

when isMainModule:
  import std/sequtils

  import pkg/stew/byteutils
  import pkg/questionable
  import pkg/questionable/results

  var
    leafs = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q"]
      .mapIt(
        MultiHash.digest("sha2-256", it.toBytes).tryGet().data.buffer
      )
    tree = MerkleTree.init(leafs).tryGet()

  tree.buildSync().tryGet
  echo tree.root().tryGet()
