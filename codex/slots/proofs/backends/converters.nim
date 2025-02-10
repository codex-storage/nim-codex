## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/circomcompat

import ../../../contracts
import ../../types
import ../../../merkletree

type
  CircomG1* = G1
  CircomG2* = G2

  CircomProof* = Proof
  CircomKey* = VerifyingKey
  CircomInputs* = Inputs

proc toCircomInputs*(inputs: ProofInputs[Poseidon2Hash]): CircomInputs =
  var
    slotIndex = inputs.slotIndex.toF.toBytes.toArray32
    datasetRoot = inputs.datasetRoot.toBytes.toArray32
    entropy = inputs.entropy.toBytes.toArray32

    elms = [entropy, datasetRoot, slotIndex]

  let inputsPtr = allocShared0(32 * elms.len)
  copyMem(inputsPtr, addr elms[0], elms.len * 32)

  CircomInputs(elms: cast[ptr array[32, byte]](inputsPtr), len: elms.len.uint)

proc releaseCircomInputs*(inputs: var CircomInputs) =
  if not inputs.elms.isNil:
    deallocShared(inputs.elms)
    inputs.elms = nil

func toG1*(g: CircomG1): G1Point =
  G1Point(x: UInt256.fromBytesLE(g.x), y: UInt256.fromBytesLE(g.y))

func toG2*(g: CircomG2): G2Point =
  G2Point(
    x: Fp2Element(real: UInt256.fromBytesLE(g.x[0]), imag: UInt256.fromBytesLE(g.x[1])),
    y: Fp2Element(real: UInt256.fromBytesLE(g.y[0]), imag: UInt256.fromBytesLE(g.y[1])),
  )

func toGroth16Proof*(proof: CircomProof): Groth16Proof =
  Groth16Proof(a: proof.a.toG1, b: proof.b.toG2, c: proof.c.toG1)
