## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/algorithm

import ./protocol/constants

func isIndexInRanges*(
    index: uint64, ranges: openArray[(uint64, uint64)], sortedRanges: bool = false
): bool =
  func binarySearch(r: openArray[(uint64, uint64)]): bool =
    var
      lo = 0
      hi = r.len - 1
      candidate = -1

    while lo <= hi:
      let mid = (lo + hi) div 2
      if r[mid][0] <= index:
        candidate = mid
        lo = mid + 1
      else:
        hi = mid - 1

    if candidate >= 0:
      let (start, count) = r[candidate]
      return index < start + count

    return false

  if ranges.len == 0:
    return false

  if sortedRanges:
    binarySearch(ranges)
  else:
    let sorted = @ranges.sorted(
      proc(a, b: (uint64, uint64)): int =
        cmp(a[0], b[0])
    )
    binarySearch(sorted)

proc computeBatchSize*(blockSize: uint32): uint32 =
  doAssert blockSize > 0, "computeBatchSize requires blockSize > 0"
  let
    optimal = TargetBatchBytes div blockSize
    maxFromBytes = MaxWantBlocksResponseBytes div blockSize
  return clamp(optimal, MinBatchSize, maxFromBytes)
