## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/poseidon2
import pkg/poseidon2/io

import ../../codextypes
import ../../merkletree
import ../../errors

func toCellCid*(cell: Poseidon2Hash): ?!Cid =
  let
    cellMhash = ? MultiHash.init(Pos2Bn128MrklCodec, cell.toBytes).mapFailure
    cellCid = ? Cid.init(CIDv1, CodexSlotCellCodec, cellMhash).mapFailure

  success cellCid

func toSlotCid*(root: Poseidon2Hash): ?!Cid =
  let
    mhash = ? MultiHash.init($multiCodec("identity"), root.toBytes).mapFailure
    treeCid = ? Cid.init(CIDv1, SlotRootCodec, mhash).mapFailure

  success treeCid

func toSlotCids*(slotRoots: openArray[Poseidon2Hash]): ?!seq[Cid] =
  success slotRoots.mapIt( ? it.toSlotCid )

func toSlotsRootsCid*(root: Poseidon2Hash): ?!Cid =
  let
    mhash = ? MultiHash.init($multiCodec("identity"), root.toBytes).mapFailure
    treeCid = ? Cid.init(CIDv1, SlotProvingRootCodec, mhash).mapFailure

  success treeCid

func toEncodableProof*(
  proof: Poseidon2Proof): ?!CodexProof =

  let
    encodableProof = CodexProof(
      mcodec: multiCodec("identity"), # copy bytes as is
      index: proof.index,
      nleaves: proof.nleaves,
      path: proof.path.mapIt( @( it.toBytes ) ))

  success encodableProof

func toVerifiableProof*(
  proof: CodexProof): ?!Poseidon2Proof =

  let
    verifiableProof = Poseidon2Proof(
      index: proof.index,
      nleaves: proof.nleaves,
      path: proof.path.mapIt(
        ? Poseidon2Hash.fromBytes(it.toArray32).toFailure
      ))

  success verifiableProof
