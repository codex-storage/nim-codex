## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import ../stores

type
  ProverBackend* = ref object of RootObj
    maxDepth            : int   ## maximum depth of the slot Merkle tree (so max `2^maxDepth` cells in a slot)
    maxLog2NSlots       : int   ## maximum depth of the dataset-level Merkle tree (so max 2^8 slots per dataset)
    blockTreeDepth      : int   ## depth of the "network block tree" (= log2(64k / 2k))
    nFieldElemsPerCell  : int   ## number of field elements per cell
    nSamples:           : int   ## number of samples

  ProofBackend* = ref object of Backend
  VerifyBackend* = ref object of Backend

method release*(self: ProverBackend) {.base.} =
  ## release the backend
  ##

  raiseAssert("not implemented!")

method prove*(
  self: ProofBackend,
  entropy: seq[byte],                     ## public input
  dataSetRoot: seq[byte];                 ## public input
  slotIndex: int,                         ## must be public, otherwise we could prove a different slot
  slotRoot: seq[byte]                     ## can be private input
  nCellsPerSlot: int,                     ## can be private input (Merkle tree is safe)
  nSlotsPerDataSet: int,                  ## can be private input (Merkle tree is safe)
  slotProof: seq[byte],                   ## path from the slot root the the dataset root (private input)
  cellData: seq[seq[byte]],               ## data for the cells (private input)
  merklePaths[nSamples][maxDepth])        ## Merkle paths for the cells (private input)
  : Future[?!seq[byte]] {.async.} =
  ## encode buffers using a backend
  ##

  raiseAssert("not implemented!")

method verify*(
    self: VerifyBackend,
    buffers,
    parity,
    recovered: var openArray[seq[byte]]
): Result[void, cstring] {.base.} =
  ## decode buffers using a backend
  ##

  raiseAssert("not implemented!")
