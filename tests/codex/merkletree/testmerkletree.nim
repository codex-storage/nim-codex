import pkg/libp2p
import std/unittest
import std/bitops
import codex/merkletree/merkletree
import ../helpers

checksuite "merkletree":
  test "addLeaf":
    let mcodec = multiCodec("sha2-256")
    var data: array[0..31, byte]
    data[0] = 0xFF

    let hash = MultiHash.digest($mcodec, data).tryGet()
    let builder = MerkleTreeBuilder()

    discard builder.addLeaf(hash)
    discard builder.addLeaf(hash)
    discard builder.addLeaf(hash)
    let tree = builder.build()

    echo "tree is" & $tree
