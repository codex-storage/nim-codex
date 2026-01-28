import pkg/chronos
import pkg/questionable/results
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/manifest

import pkg/codex/merkletree

import ../asynctest
import ./helpers
import ./examples

suite "Manifest":
  let manifest =
    Manifest.new(treeCid = Cid.example, blockSize = 1.MiBs, datasetSize = 100.MiBs)

  proc encodeDecode(manifest: Manifest): Manifest =
    let e = manifest.encode().tryGet()
    Manifest.decode(e).tryGet()

  test "Should encode/decode to/from base manifest":
    check:
      encodeDecode(manifest) == manifest

  test "Should encode/decode large manifest":
    let large = Manifest.new(
      treeCid = Cid.example,
      blockSize = (64 * 1024).NBytes,
      datasetSize = (5 * 1024).MiBs,
    )

    check:
      encodeDecode(large) == large
