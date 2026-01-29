import pkg/unittest2

import pkg/questionable/results
import pkg/stew/byteutils

import pkg/storage/merkletree
import ./helpers

const data = [
  "00000000000000000000000000000001".toBytes,
  "00000000000000000000000000000002".toBytes,
  "00000000000000000000000000000003".toBytes,
  "00000000000000000000000000000004".toBytes,
  "00000000000000000000000000000005".toBytes,
  "00000000000000000000000000000006".toBytes,
  "00000000000000000000000000000007".toBytes,
  "00000000000000000000000000000008".toBytes,
  "00000000000000000000000000000009".toBytes, "00000000000000000000000000000010".toBytes,
]

suite "merkletree - coders":
  test "encoding and decoding a tree yields the same tree":
    let
      tree = StorageMerkleTree.init(Sha256HashCodec, data).tryGet()
      encodedBytes = tree.encode()
      decodedTree = StorageMerkleTree.decode(encodedBytes).tryGet()

    check:
      tree == decodedTree

  test "encoding and decoding a proof yields the same proof":
    let
      tree = StorageMerkleTree.init(Sha256HashCodec, data).tryGet()
      proof = tree.getProof(4).tryGet()

    check:
      proof.verify(tree.leaves[4], tree.root.tryGet).isOk

    let
      encodedBytes = proof.encode()
      decodedProof = StorageMerkleProof.decode(encodedBytes).tryGet()

    check:
      proof == decodedProof
