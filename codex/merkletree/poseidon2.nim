## Logos Storage
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[sequtils, atomics]

import pkg/poseidon2
import pkg/taskpools
import pkg/chronos/threadsync
import pkg/constantine/math/io/io_fields
import pkg/constantine/platforms/abstractions
import pkg/questionable/results

import ../utils
import ../rng

import ./merkletree

export merkletree, poseidon2

const
  KeyNoneF = F.fromHex("0x0")
  KeyBottomLayerF = F.fromHex("0x1")
  KeyOddF = F.fromHex("0x2")
  KeyOddAndBottomLayerF = F.fromHex("0x3")

  Poseidon2Zero* = zero

type
  Bn254Fr* = F
  Poseidon2Hash* = Bn254Fr

  PoseidonKeysEnum* = enum # can't use non-ordinals as enum values
    KeyNone
    KeyBottomLayer
    KeyOdd
    KeyOddAndBottomLayer

  Poseidon2Tree* = MerkleTree[Poseidon2Hash, PoseidonKeysEnum]
  Poseidon2Proof* = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]

proc len*(v: Poseidon2Hash): int =
  sizeof(v)

proc assign*(v: var openArray[byte], h: Poseidon2Hash) =
  doAssert v.len == sizeof(h)
  copyMem(addr v[0], addr h, sizeof(h))

proc assign*(h: var Poseidon2Hash, v: openArray[byte]) =
  doAssert v.len == sizeof(h)
  copyMem(addr h, addr v[0], sizeof(h))

proc `$`*(self: Poseidon2Tree): string =
  let root = if self.root.isOk: self.root.get.toHex else: "none"
  "Poseidon2Tree(" & " root: " & root & ", leavesCount: " & $self.leavesCount &
    ", levels: " & $self.levels & " )"

proc `$`*(self: Poseidon2Proof): string =
  "Poseidon2Proof(" & " nleaves: " & $self.nleaves & ", index: " & $self.index &
    ", path: " & $self.path.mapIt(it.toHex) & " )"

func toArray32*(bytes: openArray[byte]): array[32, byte] =
  result[0 ..< bytes.len] = bytes[0 ..< bytes.len]

converter toKey*(key: PoseidonKeysEnum): Poseidon2Hash =
  case key
  of KeyNone: KeyNoneF
  of KeyBottomLayer: KeyBottomLayerF
  of KeyOdd: KeyOddF
  of KeyOddAndBottomLayer: KeyOddAndBottomLayerF

proc initTree(leaves: openArray[Poseidon2Hash]): ?!Poseidon2Tree =
  if leaves.len == 0:
    return failure "Empty leaves"

  let compressor = proc(
      x, y: Poseidon2Hash, key: PoseidonKeysEnum
  ): ?!Poseidon2Hash {.noSideEffect.} =
    success compress(x, y, key.toKey)

  var self = Poseidon2Tree()
  ?self.prepare(compressor, Poseidon2Zero, leaves)
  success self

func init*(_: type Poseidon2Tree, leaves: openArray[Poseidon2Hash]): ?!Poseidon2Tree =
  let self = ?initTree(leaves)
  ?self.compute()

  success self

proc init*(
    _: type Poseidon2Tree, tp: Taskpool, leaves: seq[Poseidon2Hash]
): Future[?!Poseidon2Tree] {.async: (raises: [CancelledError]).} =
  let self = ?initTree(leaves)

  ?await self.compute(tp)

  success self

func init*(_: type Poseidon2Tree, leaves: openArray[array[31, byte]]): ?!Poseidon2Tree =
  Poseidon2Tree.init(leaves.mapIt(Poseidon2Hash.fromBytes(it)))

proc init*(
    _: type Poseidon2Tree, tp: Taskpool, leaves: seq[array[31, byte]]
): Future[?!Poseidon2Tree] {.async: (raises: [CancelledError]).} =
  await Poseidon2Tree.init(tp, leaves.mapIt(Poseidon2Hash.fromBytes(it)))

proc fromNodes*(
    _: type Poseidon2Tree, nodes: openArray[Poseidon2Hash], nleaves: int
): ?!Poseidon2Tree =
  let compressor = proc(
      x, y: Poseidon2Hash, key: PoseidonKeysEnum
  ): ?!Poseidon2Hash {.noSideEffect.} =
    success compress(x, y, key.toKey)

  let self = Poseidon2Tree()
  ?self.fromNodes(compressor, Poseidon2Zero, nodes, nleaves)

  let
    index = Rng.instance.rand(nleaves - 1)
    proof = ?self.getProof(index)

  if not ?proof.verify(self.leaves[index], ?self.root): # sanity check
    return failure "Unable to verify tree built from nodes"

  success self

func init*(
    _: type Poseidon2Proof, index: int, nleaves: int, nodes: openArray[Poseidon2Hash]
): ?!Poseidon2Proof =
  if nodes.len == 0:
    return failure "Empty nodes"

  let compressor = proc(
      x, y: Poseidon2Hash, key: PoseidonKeysEnum
  ): ?!Poseidon2Hash {.noSideEffect.} =
    success compress(x, y, key.toKey)

  success Poseidon2Proof(
    compress: compressor,
    zero: Poseidon2Zero,
    index: index,
    nleaves: nleaves,
    path: @nodes,
  )
