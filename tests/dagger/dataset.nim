import std/sequtils

import pkg/chronos
import pkg/asynctest
import pkg/stew/results
import pkg/dagger/chunker
import pkg/dagger/merkletree
import pkg/stew/byteutils
import pkg/dagger/p2p/rng
import pkg/dagger/blocktype as bt

suite "Data set":

  test "Make from Blocks":
    let
      chunker = newRandomChunker(Rng.instance(), size = 256*3, chunkSize = 256)
      blocks = chunker.mapIt( bt.Block.new(it) )

    let merkle = MerkleTreeRef.fromBlocks(blocks)

