import std/unittest
import std/sequtils
import std/random

import pkg/constantine/math/arithmetic

import pkg/poseidon2
import pkg/poseidon2/io
import pkg/poseidon2/sponge

import pkg/questionable/results

import pkg/codex/merkletree
import pkg/codex/utils/digest

suite "Digest - MerkleTree":

  const KB = 1024

  test "Hashes chunks of data with sponge, and combines them in merkle root":
    let bytes = newSeqWith(64*KB, rand(byte))
    var leaves: seq[Poseidon2Hash]
    for i in 0..<32:
      let
        chunk = bytes[(i*2*KB)..<((i+1)*2*KB)]
        digest = Sponge.digest(chunk, rate = 2)
      leaves.add(digest)

    let
      digestTree = Poseidon2MerkleTree.digest(bytes, chunkSize = 2*KB).tryGet
      tree = Poseidon2MerkleTree.init(leaves).tryGet
      root = tree.root.tryGet
      expected = digestTree.root.tryGet

    check bool( root == expected )

  test "Handles partial chunk at the end":

    let bytes = newSeqWith(63*KB, rand(byte))
    var leaves: seq[Poseidon2Hash]
    for i in 0..<31:
      let
        chunk = bytes[(i*2*KB)..<((i+1)*2*KB)]
        digest = Sponge.digest(chunk, rate = 2)
      leaves.add(digest)

    let partialChunk = bytes[(62*KB)..<(63*KB)]
    leaves.add(Sponge.digest(partialChunk, rate = 2))

    let
      digestTree = Poseidon2MerkleTree.digest(bytes, chunkSize = 2*KB).tryGet
      tree = Poseidon2MerkleTree.init(leaves).tryGet
      root = tree.root.tryGet
      expected = digestTree.root.tryGet

    check bool( root == expected )
