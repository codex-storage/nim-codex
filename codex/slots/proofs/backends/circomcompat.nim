## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/questionable/results
import pkg/circomcompat

import ../../../stores
import ../../types

const
  DefaultMaxDepth            = 32  ## maximum depth of the slot Merkle tree (so max `2^maxDepth` cells in a slot)
  DefaultMaxLog2NSlots       = 8   ## maximum depth of the dataset-level Merkle tree (so max 2^8 slots per dataset)
  DefaultBlockTreeDepth      = 5   ## depth of the "network block tree" (= log2(64k / 2k))
  DefaultNFieldElemsPerCell  = 67  ## number of field elements per cell
  DefaultNSamples            = 5   ## number of samples

type
  CircomCompat*[H, P] = ref object of RootObj
    maxDepth            : int   ## maximum depth of the slot Merkle tree (so max `2^maxDepth` cells in a slot)
    maxLog2NSlots       : int   ## maximum depth of the dataset-level Merkle tree (so max 2^8 slots per dataset)
    blockTreeDepth      : int   ## depth of the "network block tree" (= log2(64k / 2k))
    nFieldElemsPerCell  : int   ## number of field elements per cell
    nSamples            : int   ## number of samples
    backend             : ptr CircomCompatCtx

func maxDepth*[H, P](self: CircomCompat[H, P]) =
  ## maximum depth of the slot Merkle tree (so max `2^maxDepth` cells in a slot)
  ##

  self.maxDepth

func maxLog2NSlots*[H, P](self: CircomCompat[H, P]) =
  ## maximum depth of the dataset-level Merkle tree (so max 2^8 slots per dataset)
  ##

  self.maxLog2NSlots

func blockTreeDepth*[H, P](self: CircomCompat[H, P]) =
  ## depth of the "network block tree" (= log2(64k / 2k))
  ##

  self.blockTreeDepth

func nFieldElemsPerCell*[H, P](self: CircomCompat[H, P]) =
  ## number of field elements per cell
  ##

  self.nFieldElemsPerCell

func nSamples*[H, P](self: CircomCompat[H, P]) =
  ## number of samples
  ##

  self.nSamples

method release*[H, P](self: CircomCompat[H, P]) {.base.} =
  ## release the backend
  ##

  release_circom_compat(self.backend.addr)

method prove*[H, P](
  self: CircomCompat[H, P],
  input: ProofInput[H, P]): Future[?!seq[byte]] {.base, async.} =
  ## encode buffers using a backend
  ##

  raiseAssert("not implemented!")

proc new*[H, P](
  _: type CircomCompat[H, P],
  r1csPath: string,
  wasmPath: string,
  zKeyPath: string,
  maxDepth = DefaultMaxDepth,
  maxLog2NSlots = DefaultMaxLog2NSlots,
  blockTreeDepth = DefaultBlockTreeDepth,
  nFieldElemsPerCell = DefaultNFieldElemsPerCell,
  nSamples = DefaultNSamples): CircomCompat[H, P] =
  ## Create a new backend
  ##

  var backend: ptr CircomCompatCtx
  if initCircomCompat(
    r1csPath.cstring,
    wasmPath.cstring,
    zKeyPath.cstring,
    addr backend) != ERR_OK or backend == nil:
    raiseAssert("failed to initialize CircomCompat backend")

  CircomCompat[H, P](
    maxDepth: maxDepth,
    maxLog2NSlots: maxLog2NSlots,
    blockTreeDepth: blockTreeDepth,
    nFieldElemsPerCell: nFieldElemsPerCell,
    nSamples: nSamples,
    backend: backend)
