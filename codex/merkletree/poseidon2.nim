## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/poseidon2
import pkg/constantine/math/io/io_fields
import pkg/questionable/results

import ./merkletree

export merkletree, poseidon2

const
  KeyNoneF              = F.fromhex("0x0")
  KeyBottomLayerF       = F.fromhex("0x1")
  KeyOddF               = F.fromhex("0x2")
  KeyOddAndBottomLayerF = F.fromhex("0x3")

type
  Poseidon2Hash* = F

  PoseidonKeysEnum = enum  # can't use non-ordinals as enum values
    KeyNone               = "0x0"
    KeyBottomLayer        = "0x1"
    KeyOdd                = "0x2"
    KeyOddAndBottomLayer  = "0x3"

  Poseidon2MerkleTree* = MerkleTree[Poseidon2Hash, PoseidonKeysEnum]
  Poseidon2MerkleProof* = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]

converter toKey(key: PoseidonKeysEnum): Poseidon2Hash =
  case key:
  of KeyNone: KeyNoneF
  of KeyBottomLayer: KeyBottomLayerF
  of KeyOdd: KeyOddF
  of KeyOddAndBottomLayer: KeyOddAndBottomLayerF

func init*(_: type Poseidon2MerkleTree, leaves: openArray[Poseidon2Hash]): ?!Poseidon2MerkleTree =
  let
    compressor = proc(
      x, y: Poseidon2Hash,
      key: PoseidonKeysEnum): ?!Poseidon2Hash {.noSideEffect.} =
      success compress( x, y, key.toKey )

  var
    self = Poseidon2MerkleTree(compress: compressor, zero: zero)

  self.layers = ? merkleTreeWorker(self, leaves, isBottomLayer = true)
  success self

func init*(_: type Poseidon2MerkleTree, leaves: openArray[array[31, byte]]): ?!Poseidon2MerkleTree =
  success Poseidon2MerkleProof.init(
    leaves.mapIt( Poseidon2Hash.fromOpenArray(it) ))
