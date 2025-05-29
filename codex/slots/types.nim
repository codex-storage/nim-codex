## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

type
  Sample*[SomeHash] = object
    cellData*: seq[SomeHash]
    merklePaths*: seq[SomeHash]

  PublicInputs*[SomeHash] = object
    slotIndex*: int
    datasetRoot*: SomeHash
    entropy*: SomeHash

  ProofInputs*[SomeHash] = object
    entropy*: SomeHash
    datasetRoot*: SomeHash
    slotIndex*: Natural
    slotRoot*: SomeHash
    nCellsPerSlot*: Natural
    nSlotsPerDataSet*: Natural
    slotProof*: seq[SomeHash]
      # inclusion proof that shows that the slot root (leaf) is part of the dataset (root)
    samples*: seq[Sample[SomeHash]]
      # inclusion proofs which show that the selected cells (leafs) are part of the slot (roots)
