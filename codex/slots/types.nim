## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

type
  Sample*[H] = object
    cellData*: seq[byte]
    merklePaths*: seq[H]

  PublicInputs*[H] = object
    slotIndex*: int
    datasetRoot*: H
    entropy*: H

  ProofInput*[H] = object
    entropy*: H
    datasetRoot*: H
    slotIndex*: Natural
    slotRoot*: H
    nCellsPerSlot*: Natural
    nSlotsPerDataSet*: Natural
    slotProof*: seq[H]
    samples*: seq[Sample[H]]
