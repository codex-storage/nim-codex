## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/poseidon2
import pkg/poseidon2/io
import pkg/questionable/results

import ../merkletree

func digest*(
  _: type Poseidon2MerkleTree,
  bytes: openArray[byte], chunkSize: int): ?!Poseidon2MerkleTree =
  ## Hashes chunks of data with a sponge of rate 2, and combines the
  ## resulting chunk hashes in a merkle root.
  ##

  var index = 0
  var leaves: seq[Poseidon2Hash]
  while index < bytes.len:
    let start = index
    let finish = min(index + chunkSize, bytes.len)
    let digest = Sponge.digest(bytes.toOpenArray(start, finish - 1), rate = 2)
    leaves.add(digest)
    index += chunkSize
  return Poseidon2MerkleTree.init(leaves)
