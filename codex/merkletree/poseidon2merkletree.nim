## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/poseidon2
import pkg/constantine/math/io/io_fields

import ./merkletree

export merkletree, poseidon2

type
  Poseidon2Hash* = F

  PoseidonKeysEnum* {.pure.} = enum
    KeyNone               = "0x0"
    KeyBottomLayer        = "0x1"
    KeyOdd                = "0x2"
    KeyOddAndBottomLayer  = "0x3"

  MerkleTreePoseidon2* = MerkleTree[Poseidon2Hash, PoseidonKeysEnum]
  MerkleProofPoseidon2* = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]

converter toKey*(x: PoseidonKeysEnum): Poseidon2Hash =
  return Poseidon2Hash.fromHex($x)

func init*(_: type MerkleTreePoseidon2, leaves: seq[Poseidon2Hash]): MerkleTreePoseidon2 =
  let
    compress = proc(
      x, y: Poseidon2Hash,
      key: PoseidonKeysEnum): Poseidon2Hash {.noSideEffect.} =
      poseidon2.compress( x, y, key )

  MerkleTreePoseidon2(compress: compress, leaves: leaves, zero: zero)
