## Nim-Codex
## Copyright (c) 2025 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
import pkg/questionable/results

import std/math

import ../manifest

const maxBlocks = 2147483648.uint64 # 2^31 - maximum for 2D grid

func calculate2DErasureParams*(numBlocks: uint64): ?!(int, int) =
  ## Calculate K and M for 2D erasure coding for ~2x output with GF(2^16) constraint
  if numBlocks > maxBlocks:
    return failure(
      "Dataset too large: " & $numBlocks & " blocks exceeds maximum of " & $maxBlocks &
        " blocks for 2D erasure coding"
    )

  let
    totalDim = min(round(sqrt(2.0 * numBlocks.float)).int, 65536)
    minK = ceil(sqrt(numBlocks.float)).int
    k = max(minK, round(totalDim.float / sqrt(2.0)).int)
    m = max(1, min(totalDim - k, 65536 - k))

  success (k, m)

func calculate2DSlotBlocks*(manifest: Manifest): ?!Natural =
  ## Calculate number of blocks per slot for 2D encoding
  if not manifest.protected:
    return failure("2D encoding requires a protected manifest")

  let numSlotBlocks = manifest.numSlotBlocks
  without (ecK, ecM) =? calculate2DErasureParams(numSlotBlocks.uint64), err:
    return failure(err)

  success ((ecK + ecM) * (ecK + ecM)).Natural
