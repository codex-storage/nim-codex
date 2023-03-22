## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines Manifest and all related types

import std/tables
import pkg/libp2p
import pkg/questionable

const
  BlockCodec* = multiCodec("raw")
  DagPBCodec* = multiCodec("dag-pb")

type
  ManifestCoderType*[codec: static MultiCodec] = object
  DagPBCoder* = ManifestCoderType[multiCodec("dag-pb")]

const
  ManifestContainers* = {
    $DagPBCodec: DagPBCoder()
  }.toTable

type
  Manifest* = ref object of RootObj
    rootHash*: ?Cid         # Root (tree) hash of the contained data set
    originalBytes*: int     # Exact size of the original (uploaded) file
    blockSize*: int         # Size of each contained block (might not be needed if blocks are len-prefixed)
    blocks*: seq[Cid]       # Block Cid
    version*: CidVersion    # Cid version
    hcodec*: MultiCodec     # Multihash codec
    codec*: MultiCodec      # Data set codec
    case protected*: bool   # Protected datasets have erasure coded info
    of true:
      ecK*: int               # Number of blocks to encode
      ecM*: int               # Number of resulting parity blocks
      originalCid*: Cid     # The original Cid of the dataset being erasure coded
      originalLen*: int     # The length of the original manifest
    else:
      discard
