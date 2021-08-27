
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils as stew

import pkg/dagger/chunker
import pkg/dagger/rng
import pkg/dagger/blocktype as bt
import pkg/dagger/blockstream
import pkg/dagger/blockset

suite "Data set":
  test "Make from Blocks":
    let
      blockStream = ChunkedBlockStreamRef.new(
        newRandomChunker(Rng.instance(), size = 256 * 7, chunkSize = 256))
      blockSet = BlockSetRef.new(stream = blockStream)

    let res = blockSet.treeHash()
    check res.isOK
    if h =? res:
      echo h.hashBytes()
      return

    echo res.error.msg
