## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils

import pkg/chronos
import pkg/poseidon2
import pkg/constantine/math/io/io_fields
import pkg/constantine/platforms/abstractions
import pkg/questionable/results

import ../utils
import ../rng

import ./merkletree

export merkletree, poseidon2

const
  KeyNoneF              = F.fromhex("0x0")
  KeyBottomLayerF       = F.fromhex("0x1")
  KeyOddF               = F.fromhex("0x2")
  KeyOddAndBottomLayerF = F.fromhex("0x3")

  Poseidon2Zero* = zero

type
  Bn254Fr* = F
  Poseidon2Hash* = Bn254Fr

  PoseidonKeysEnum* = enum  # can't use non-ordinals as enum values
    KeyNone
    KeyBottomLayer
    KeyOdd
    KeyOddAndBottomLayer

  Poseidon2Tree* = MerkleTree[Poseidon2Hash, PoseidonKeysEnum]
  Poseidon2Proof* = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]

proc `$`*(self: Poseidon2Tree): string =
  let root = if self.root.isOk: self.root.get.toHex else: "none"
  "Poseidon2Tree(" &
    " root: " & root &
    ", leavesCount: " & $self.leavesCount &
    ", levels: " & $self.levels & " )"

proc `$`*(self: Poseidon2Proof): string =
  "Poseidon2Proof(" &
  " nleaves: " & $self.nleaves &
  ", index: " & $self.index &
  ", path: " & $self.path.mapIt( it.toHex ) & " )"

func toArray32*(bytes: openArray[byte]): array[32, byte] =
  result[0..<bytes.len] = bytes[0..<bytes.len]

converter toKey*(key: PoseidonKeysEnum): Poseidon2Hash =
  case key:
  of KeyNone: KeyNoneF
  of KeyBottomLayer: KeyBottomLayerF
  of KeyOdd: KeyOddF
  of KeyOddAndBottomLayer: KeyOddAndBottomLayerF

proc init*(
  _: type Poseidon2Tree,
  leaves: seq[Poseidon2Hash]): Future[?!Poseidon2Tree] {.async.} =

  if leaves.len == 0:
    return failure "Empty leaves"

  let
    compressor = proc(
      x, y: Poseidon2Hash,
      key: PoseidonKeysEnum): ?!Poseidon2Hash {.noSideEffect.} =
      success compress( x, y, key.toKey )

  var
    self = Poseidon2Tree(compress: compressor, zero: Poseidon2Zero)

  without l =? (await merkleTreeWorker(self, leaves, isBottomLayer = true)), error:
    return failure error
  self.layers = l
  success self

proc init*(
  _: type Poseidon2Tree,
  leaves: seq[array[31, byte]]): Future[?!Poseidon2Tree] {.async.} =
  await Poseidon2Tree.init(
    leaves.mapIt( Poseidon2Hash.fromBytes(it) ))

proc fromNodes*(
  _: type Poseidon2Tree,
  nodes: openArray[Poseidon2Hash],
  nleaves: int): ?!Poseidon2Tree =

  if nodes.len == 0:
    return failure "Empty nodes"

  let
    compressor = proc(
      x, y: Poseidon2Hash,
      key: PoseidonKeysEnum): ?!Poseidon2Hash {.noSideEffect.} =
      success compress( x, y, key.toKey )

  var
    self = Poseidon2Tree(compress: compressor, zero: zero)
    layer = nleaves
    pos = 0

  while pos < nodes.len:
    self.layers.add( nodes[pos..<(pos + layer)] )
    pos += layer
    layer = divUp(layer, 2)

  let
    index = Rng.instance.rand(nleaves - 1)
    proof = ? self.getProof(index)

  if not ? proof.verify(self.leaves[index], ? self.root): # sanity check
    return failure "Unable to verify tree built from nodes"

  success self

func init*(
  _: type Poseidon2Proof,
  index: int,
  nleaves: int,
  nodes: openArray[Poseidon2Hash]): ?!Poseidon2Proof =

  if nodes.len == 0:
    return failure "Empty nodes"

  let
    compressor = proc(
      x, y: Poseidon2Hash,
      key: PoseidonKeysEnum): ?!Poseidon2Hash {.noSideEffect.} =
      success compress( x, y, key.toKey )

  success Poseidon2Proof(
    compress: compressor,
    zero: Poseidon2Zero,
    index: index,
    nleaves: nleaves,
    path: @nodes)
