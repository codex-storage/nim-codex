## Nim-Codex
## Copyright (c) 2025 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/groth16
import pkg/circomcompat
import pkg/constantine/math/io/io_fields

import ../../../contracts
import ../../types
import ../../../merkletree

type
  CircomCompatG1* = circomcompat.G1
  CircomCompatG2* = circomcompat.G2

  CircomCompatProof* = circomcompat.Proof
  CircomCompatKey* = circomcompat.VerifyingKey
  CircomCompatInputs* = circomcompat.Inputs

  NimGroth16G1* = groth16.G1
  NimGroth16G2* = groth16.G2
  NimGroth16Proof* = groth16.Proof

proc toCircomInputs*(inputs: ProofInputs[Poseidon2Hash]): CircomCompatInputs =
  var
    slotIndex = inputs.slotIndex.toF.toBytes.toArray32
    datasetRoot = inputs.datasetRoot.toBytes.toArray32
    entropy = inputs.entropy.toBytes.toArray32

    elms = [entropy, datasetRoot, slotIndex]

  let inputsPtr = allocShared0(32 * elms.len)
  copyMem(inputsPtr, addr elms[0], elms.len * 32)

  CircomCompatInputs(elms: cast[ptr array[32, byte]](inputsPtr), len: elms.len.uint)

proc releaseCircomInputs*(inputs: var CircomCompatInputs) =
  if not inputs.elms.isNil:
    deallocShared(inputs.elms)
    inputs.elms = nil

func toG1*(g: CircomCompatG1): G1Point =
  G1Point(x: UInt256.fromBytesLE(g.x), y: UInt256.fromBytesLE(g.y))

func toG2*(g: CircomCompatG2): G2Point =
  G2Point(
    x: Fp2Element(real: UInt256.fromBytesLE(g.x[0]), imag: UInt256.fromBytesLE(g.x[1])),
    y: Fp2Element(real: UInt256.fromBytesLE(g.y[0]), imag: UInt256.fromBytesLE(g.y[1])),
  )

func toGroth16Proof*(proof: CircomCompatProof): Groth16Proof =
  Groth16Proof(a: proof.a.toG1, b: proof.b.toG2, c: proof.c.toG1)

func toG1*(g: NimGroth16G1): G1Point =
  var
    x: array[32, byte]
    y: array[32, byte]

  assert x.marshal(g.x, Endianness.littleEndian)
  assert y.marshal(g.y, Endianness.littleEndian)

  G1Point(x: UInt256.fromBytesLE(x), y: UInt256.fromBytesLE(y))

func toG2*(g: NimGroth16G2): G2Point =
  var
    x: array[2, array[32, byte]]
    y: array[2, array[32, byte]]

  assert x[0].marshal(g.x.coords[0], Endianness.littleEndian)
  assert x[1].marshal(g.x.coords[1], Endianness.littleEndian)
  assert y[0].marshal(g.y.coords[0], Endianness.littleEndian)
  assert y[1].marshal(g.y.coords[1], Endianness.littleEndian)

  G2Point(
    x: Fp2Element(real: UInt256.fromBytesLE(x[0]), imag: UInt256.fromBytesLE(x[1])),
    y: Fp2Element(real: UInt256.fromBytesLE(y[0]), imag: UInt256.fromBytesLE(y[1])),
  )

func toGroth16Proof*(proof: NimGroth16Proof): Groth16Proof =
  Groth16Proof(a: proof.pi_a.toG1, b: proof.pi_b.toG2, c: proof.pi_c.toG1)
