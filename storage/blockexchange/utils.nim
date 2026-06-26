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
import ./protocol/message

func isIndexInRanges*(
    index: uint64, ranges: openArray[Range], sortedRanges: bool = false
): bool =
  func binarySearch(r: openArray[Range]): bool =
    var
      lo = 0
      hi = r.len - 1
      candidate = -1

    while lo <= hi:
      let mid = (lo + hi) div 2
      if r[mid].start <= index:
        candidate = mid
        lo = mid + 1
      else:
        hi = mid - 1

    if candidate >= 0:
      return index < r[candidate].start + r[candidate].count

    return false

  if ranges.len == 0:
    return false

  if sortedRanges:
    binarySearch(ranges)
  else:
    let sorted = @ranges.sorted(
      proc(a, b: Range): int =
        cmp(a.start, b.start)
    )
    binarySearch(sorted)

proc computeBatchSize*(blockSize: uint32): uint32 =
  doAssert blockSize > 0, "computeBatchSize requires blockSize > 0"
  let
    optimal = TargetBatchBytes div blockSize
    maxFromBytes = MaxWantBlocksResponseBytes div blockSize
  return clamp(optimal, MinBatchSize, maxFromBytes)
