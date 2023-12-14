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

import std/math
import std/bitops
import std/sequtils
import std/sugar
import std/algorithm
import std/tables

import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/stew/byteutils

import ../../errors
import ../../blocktype

import ../merkletree

export merkletree

logScope:
  topics = "codex merkletree"

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

func verify*(self: CodexMerkleProof, root: MultiHash): ?!void =
  ## Verify hash
  ##

  let
    bytes = root.bytes

  if self.mcodec != root.mcodec:
    return failure "Hash codec mismatch"

  if bytes.len != root.size:
    return failure "Invalid hash length"

  ? self.verify(bytes)

  success()

proc rootCid*(
  self: CodexMerkleTree,
  version = CIDv1,
  dataCodec = DatasetRootCodec): ?!Cid =

  if self.root.len == 0:
    return failure "Empty root"

  Cid.init(
    version,
    dataCodec,
    ? MultiHash.init(self.mcodec, self.root).mapFailure).mapFailure

func getLeafCid*(
  self: CodexMerkleTree,
  i: Natural,
  version = CIDv1,
  dataCodec = BlockCodec): ?!Cid =

  if i >= self.leavesCount:
    return failure "Invalid leaf index " & $i

  let
    leaf = self.leaves[i]

  Cid.init(
    CidVersion.CIDv1,
    dataCodec,
    ? MultiHash.init(self.mcodec, self.root).mapFailure).mapFailure

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
  mcodec: MultiCodec,
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

func fromNodes*(
  _: type CodexMerkleTree,
  mcodec: MultiCodec,
  nodes: openArray[seq[ByteHash]],
  nleaves: int): ?!CodexMerkleTree =

  if nodes.len == 0:
    return failure "Empty nodes"

  let
    mhash = ? mcodec.getMhash()
    Zero = newSeq[ByteHash](mhash.size)
    compressor = proc(x, y: openArray[byte], key: ByteTreeKey): ?!ByteHash {.noSideEffect.} =
      compress(x, y, key, mhash)

  if mhash.size != nodes[0].len:
    return failure "Invalid hash length"

  let
    self = CodexMerkleTree(compress: compressor, zero: Zero, mhash: mhash)

  var
    layer = nleaves
    pos = 0

  while layer > 0:
    self.layers.add( nodes[pos..<layer].toSeq() )
    pos += layer
    layer = layer shr 1

  ? self.proof(Rng.instance.rand(nleaves)).?verify(self.root) # sanity check

  success self

func init*(
  _: type CodexMerkleProof,
  mcodec: MultiCodec,
  index: int,
  nodes: openArray[ByteHash]): ?!CodexMerkleProof =

  if nodes.len == 0:
    return failure "Empty nodes"

  let
    mhash = ? mcodec.getMhash()
    Zero: ByteHash = newSeq[byte](mhash.size)
    compressor = proc(x, y: seq[byte], key: ByteTreeKey): ?!seq[byte] {.noSideEffect.} =
      compress(x, y, key, mhash)
    self = CodexMerkleProof(compress: compressor, zero: Zero, mhash: mhash)

  success self
