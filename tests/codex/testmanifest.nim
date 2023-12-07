import std/sequtils

import pkg/chronos
import pkg/questionable/results
import pkg/asynctest
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/manifest

import ./helpers
import ./examples

checksuite "Manifest":
  let
    manifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 100.MiBs
    )
    protectedManifest = Manifest.new(
      manifest = manifest,
      treeCid = Cid.example,
      datasetSize = 200.MiBs,
      eck = 10,
      ecM = 10
    )
    verifiableManifest = Manifest.new(
      manifest = protectedManifest,
      verificationRoot = Cid.example,
      slotRoots = @[Cid.example, Cid.example]
    ).tryGet()

  proc encodeDecode(manifest: Manifest): Manifest =
    let e = manifest.encode().tryGet()
    Manifest.decode(e).tryGet()

  test "Should encode/decode to/from base manifest":
    check:
      encodeDecode(manifest) == manifest

  test "Should encode/decode to/from protected manifest":
    check:
      encodeDecode(protectedManifest) == protectedManifest

  test "Should encode/decode to/from verifiable manifest":
    check:
      encodeDecode(verifiableManifest) == verifiableManifest
