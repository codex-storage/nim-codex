## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/bitops
import std/sequtils
import std/sugar

import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/stew/byteutils

import ../../utils
import ../../rng
import ../../errors
import ../../blocktype

import ../merkletree

export merkletree

logScope:
  topics = "codex merkletree"

const
  DatasetRootCodec* = multiCodec("codex-root") # TODO: move to blocktype
  BlockCodec* = multiCodec("raw") # TODO: fix multicodec to `codex-block` and move to blocktype

type
  ByteTreeKey* {.pure.} = enum
    KeyNone               = 0x0.byte
    KeyBottomLayer        = 0x1.byte
    KeyOdd                = 0x2.byte
    KeyOddAndBottomLayer  = 0x3.byte

  ByteHash* = seq[byte]
  ByteTree* = MerkleTree[ByteHash, ByteTreeKey]
  ByteTreeProof* = MerkleProof[ByteHash, ByteTreeKey]

  CodexMerkleTree* = object of ByteTree
    mhash: MHash

  CodexMerkleProof* = object of ByteTreeProof
    mhash: MHash

func getMhash*(mcodec: MultiCodec): ?!MHash =
  let
    mhash = CodeHashes.getOrDefault(mcodec)

  if isNil(mhash.coder):
    return failure "Invalid multihash codec"

  success mhash

func digestSize*(self: (CodexMerkleTree or CodexMerkleProof)): int =
  ## Number of leaves
  ##

  self.mhash.size

func mcodec*(self: (CodexMerkleTree or CodexMerkleProof)): MultiCodec =
  ## Multicodec
  ##

  self.mhash.mcodec

func bytes*(mhash: MultiHash): seq[byte] =
  ## Extract hash bytes
  ##

  mhash.data.buffer[mhash.dpos..<mhash.dpos + mhash.size]

func getProof*(self: CodexMerkleTree, index: int): ?!CodexMerkleProof =
  var
    proof = CodexMerkleProof(mhash: self.mhash)

  self.getProof(index, proof)

  success proof

func verify*(self: CodexMerkleProof, leaf: MultiHash, root: MultiHash): ?!void =
  ## Verify hash
  ##

  let
    rootBytes = root.bytes
    leafBytes = leaf.bytes

  if self.mcodec != root.mcodec or
    self.mcodec != leaf.mcodec:
    return failure "Hash codec mismatch"

  if rootBytes.len != root.size and
    leafBytes.len != leaf.size:
    return failure "Invalid hash length"

  ? self.verify(leafBytes, rootBytes)

  success()

func verify*(self: CodexMerkleProof, leaf: Cid, root: Cid): ?!void =
  self.verify(? leaf.mhash.mapFailure, ? leaf.mhash.mapFailure)

proc rootCid*(
  self: CodexMerkleTree,
  version = CIDv1,
  dataCodec = DatasetRootCodec): ?!Cid =

  if self.root.len == 0:
    return failure "Empty root"

  let
    mhash = ? MultiHash.init(self.mcodec, self.root).mapFailure

  Cid.init(version, DatasetRootCodec, mhash).mapFailure

func getLeafCid*(
  self: CodexMerkleTree,
  i: Natural,
  version = CIDv1,
  dataCodec = BlockCodec): ?!Cid =

  if i >= self.leavesCount:
    return failure "Invalid leaf index " & $i

  let
    leaf = self.leaves[i]
    mhash = ? MultiHash.init($self.mcodec, leaf).mapFailure

  Cid.init(version, dataCodec, mhash).mapFailure

proc `==`*(a, b: CodexMerkleTree): bool =
  (a.mcodec == b.mcodec) and
  (a.leavesCount == b.leavesCount) and
  (a.levels == b.levels)

proc `==`*(a, b: CodexMerkleProof): bool =
  (a.mcodec == b.mcodec) and
  (a.nleaves == b.nleaves) and
  (a.path == b.path) and
  (a.index == b.index)

proc `$`*(self: CodexMerkleTree): string =
  "CodexMerkleTree(" & $self.mcodec & ", " & $self.leavesCount & ")"

proc `$`*(self: CodexMerkleProof): string =
  "CodexMerkleProof(" &
    $self.mcodec & ", " &
    $self.nleaves & ", " &
    $self.index & ")"

func compress*(
  x, y: openArray[byte],
  key: ByteTreeKey,
  mhash: MHash): ?!ByteHash =
  ## Compress two hashes
  ##

  var digest = newSeq[byte](mhash.size)
  mhash.coder(@x & @y & @[ key.byte ], digest)
  success digest

func init*(
  _: type CodexMerkleTree,
  mcodec: MultiCodec = multiCodec("sha2-256"),
  leaves: openArray[ByteHash]): ?!CodexMerkleTree =

  if leaves.len == 0:
    return failure "Empty leaves"

  let
    mhash = ? mcodec.getMhash()
    compressor = proc(x, y: seq[byte], key: ByteTreeKey): ?!ByteHash {.noSideEffect.} =
      compress(x, y, key, mhash)
    Zero: ByteHash = newSeq[byte](mhash.size)

  if mhash.size != leaves[0].len:
    return failure "Invalid hash length"

  var
    self = CodexMerkleTree(mhash: mhash, compress: compressor, zero: Zero)

  self.layers = ? merkleTreeWorker(self, leaves, isBottomLayer = true)
  success self

func init*(
  _: type CodexMerkleTree,
  leaves: openArray[MultiHash]): ?!CodexMerkleTree =

  if leaves.len == 0:
    return failure "Empty leaves"

  let
    mcodec = leaves[0].mcodec
    leaves = leaves.mapIt( it.bytes )

  CodexMerkleTree.init(mcodec, leaves)

func init*(
  _: type CodexMerkleTree,
  leaves: openArray[Cid]): ?!CodexMerkleTree =
  if leaves.len == 0:
    return failure "Empty leaves"

  let
    mcodec = (? leaves[0].mhash.mapFailure).mcodec
    leaves = leaves.mapIt( (? it.mhash.mapFailure).bytes )

  CodexMerkleTree.init(mcodec, leaves)

proc fromNodes*(
  _: type CodexMerkleTree,
  mcodec: MultiCodec = multiCodec("sha2-256"),
  nodes: openArray[ByteHash],
  nleaves: int): ?!CodexMerkleTree =

  if nodes.len == 0:
    return failure "Empty nodes"

  let
    mhash = ? mcodec.getMhash()
    Zero = newSeq[byte](mhash.size)
    compressor = proc(x, y: seq[byte], key: ByteTreeKey): ?!ByteHash {.noSideEffect.} =
      compress(x, y, key, mhash)

  if mhash.size != nodes[0].len:
    return failure "Invalid hash length"

  var
    self = CodexMerkleTree(compress: compressor, zero: Zero, mhash: mhash)
    layer = nleaves
    pos = 0

  while pos < nodes.len:
    self.layers.add( nodes[pos..<(pos + layer)] )
    pos += layer
    layer = divUp(layer, 2)

  let
    index = Rng.instance.rand(nleaves - 1)
    proof = ? self.getProof(index)

  ? proof.verify(self.leaves[index], self.root) # sanity check
  success self

func init*(
  _: type CodexMerkleProof,
  mcodec: MultiCodec = multiCodec("sha2-256"),
  index: int,
  nleaves: int,
  nodes: openArray[ByteHash]): ?!CodexMerkleProof =

  if nodes.len == 0:
    return failure "Empty nodes"

  let
    mhash = ? mcodec.getMhash()
    Zero = newSeq[byte](mhash.size)
    compressor = proc(x, y: seq[byte], key: ByteTreeKey): ?!seq[byte] {.noSideEffect.} =
      compress(x, y, key, mhash)


  success CodexMerkleProof(
    compress: compressor,
    zero: Zero,
    mhash: mhash,
    index: index,
    nleaves: nleaves,
    path: @nodes)
