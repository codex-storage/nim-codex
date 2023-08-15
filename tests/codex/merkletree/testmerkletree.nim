import std/unittest
import std/sequtils
import std/tables

import pkg/questionable/results
import pkg/stew/byteutils
import pkg/nimcrypto/sha2

import codex/merkletree/merkletree
import ../helpers

checksuite "merkletree":
  const data =
    [
      "0123456789012345678901234567890123456789".toBytes,
      "1234567890123456789012345678901234567890".toBytes,
      "2345678901234567890123456789012345678901".toBytes,
      "3456789012345678901234567890123456789012".toBytes,
      "4567890123456789012345678901234567890123".toBytes,
      "5678901234567890123456789012345678901234".toBytes,
      "6789012345678901234567890123456789012345".toBytes,
      "7890123456789012345678901234567890123456".toBytes,
      "8901234567890123456789012345678901234567".toBytes,
      "9012345678901234567890123456789012345678".toBytes,
    ]
  var zeroHash: MerkleHash
  var expectedLeaves: array[data.len, MerkleHash]
  var builder: MerkleTreeBuilder

  proc combine(a, b: MerkleHash): MerkleHash =
    var buf = newSeq[byte](a.len + b.len)
    for i in 0..<a.len:
      buf[i] = a[i]
    for i in 0..<b.len:
      buf[i + a.len] = b[i]
    var digest = sha256.digest(buf)
    return digest.data

  setup:
    for i in 0..<data.len:
      var digest = sha256.digest(data[i])
      expectedLeaves[i] = digest.data
    
    builder = MerkleTreeBuilder()

  test "tree with one leaf has expected root":
    builder.addDataBlock(data[0])

    let tree = builder.build().tryGet()

    check:
      tree.leaves == expectedLeaves[0..0]
      tree.root == expectedLeaves[0]
      tree.len == 1

  test "tree with two leaves has expected root":
    builder.addDataBlock(data[0])
    builder.addDataBlock(data[1])

    let tree = builder.build().tryGet()

    let expectedRoot = combine(expectedLeaves[0], expectedLeaves[1])

    check:
      tree.leaves == expectedLeaves[0..1]
      tree.len == 3
      tree.root == expectedRoot

  test "tree with three leaves has expected root":
    builder.addDataBlock(data[0])
    builder.addDataBlock(data[1])
    builder.addDataBlock(data[2])

    let tree = builder.build().tryGet()

    let
      expectedRoot = combine(
        combine(expectedLeaves[0], expectedLeaves[1]), 
        combine(expectedLeaves[2], zeroHash)
      )

    check:
      tree.leaves == expectedLeaves[0..2]
      tree.len == 6
      tree.root == expectedRoot

  test "tree with ten leaves has expected root":
    builder.addDataBlock(data[0])
    builder.addDataBlock(data[1])
    builder.addDataBlock(data[2])
    builder.addDataBlock(data[3])
    builder.addDataBlock(data[4])
    builder.addDataBlock(data[5])
    builder.addDataBlock(data[6])
    builder.addDataBlock(data[7])
    builder.addDataBlock(data[8])
    builder.addDataBlock(data[9])

    let tree = builder.build().tryGet()

    let
      expectedRoot = combine(
        combine(
          combine(
            combine(expectedLeaves[0], expectedLeaves[1]),
            combine(expectedLeaves[2], expectedLeaves[3]), 
          ),
          combine( 
            combine(expectedLeaves[4], expectedLeaves[5]), 
            combine(expectedLeaves[6], expectedLeaves[7])
          )
        ),
        combine(
          combine( 
            combine(expectedLeaves[8], expectedLeaves[9]),
            zeroHash
          ),
          zeroHash
        )
      )

    check:
      tree.leaves == expectedLeaves[0..9]
      tree.len == 21
      tree.root == expectedRoot

  test "tree with two leaves provides expected proofs":
    builder.addDataBlock(data[0])
    builder.addDataBlock(data[1])

    let tree = builder.build().tryGet()

    let expectedProofs = [
      MerkleProof.init(0, @[expectedLeaves[1]]),
      MerkleProof.init(1, @[expectedLeaves[0]]),
    ]

    check:
      tree.getProof(0).tryGet() == expectedProofs[0]
      tree.getProof(1).tryGet() == expectedProofs[1]
  
  test "tree with three leaves provides expected proofs":
    builder.addDataBlock(data[0])
    builder.addDataBlock(data[1])
    builder.addDataBlock(data[2])

    let tree = builder.build().tryGet()

    let expectedProofs = [
      MerkleProof.init(0, @[expectedLeaves[1], combine(expectedLeaves[2], zeroHash)]),
      MerkleProof.init(1, @[expectedLeaves[0], combine(expectedLeaves[2], zeroHash)]),
      MerkleProof.init(2, @[zeroHash, combine(expectedLeaves[0], expectedLeaves[1])]),
    ]

    check:
      tree.getProof(0).tryGet() == expectedProofs[0]
      tree.getProof(1).tryGet() == expectedProofs[1]
      tree.getProof(2).tryGet() == expectedProofs[2]

  test "tree with ten leaves provides expected proofs":
    builder.addDataBlock(data[0])
    builder.addDataBlock(data[1])
    builder.addDataBlock(data[2])
    builder.addDataBlock(data[3])
    builder.addDataBlock(data[4])
    builder.addDataBlock(data[5])
    builder.addDataBlock(data[6])
    builder.addDataBlock(data[7])
    builder.addDataBlock(data[8])
    builder.addDataBlock(data[9])

    let tree = builder.build().tryGet()

    let expectedProofs = {
      4: 
        MerkleProof.init(4, @[
          expectedLeaves[5], 
          combine(expectedLeaves[6], expectedLeaves[7]), 
          combine(
              combine(expectedLeaves[0], expectedLeaves[1]),
              combine(expectedLeaves[2], expectedLeaves[3]), 
          ),
          combine(
            combine( 
              combine(expectedLeaves[8], expectedLeaves[9]),
              zeroHash
            ),
            zeroHash
          )
        ]),
      9: 
        MerkleProof.init(9, @[
          expectedLeaves[8], 
          zeroHash,
          zeroHash,
          combine(
            combine(
              combine(expectedLeaves[0], expectedLeaves[1]),
              combine(expectedLeaves[2], expectedLeaves[3]), 
            ),
            combine( 
              combine(expectedLeaves[4], expectedLeaves[5]), 
              combine(expectedLeaves[6], expectedLeaves[7])
            )
          )
        ]),
    }.newTable

    check:
      tree.getProof(4).tryGet() == expectedProofs[4]
      tree.getProof(9).tryGet() == expectedProofs[9]

  test "getProof fails for index out of bounds":
    builder.addDataBlock(data[0])
    builder.addDataBlock(data[1])
    builder.addDataBlock(data[2])

    let tree = builder.build().tryGet()

    check:
      isErr(tree.getProof(4))
