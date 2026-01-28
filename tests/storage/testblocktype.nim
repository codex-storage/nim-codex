import pkg/unittest2
import pkg/libp2p/cid

import pkg/codex/blocktype

import ./examples

suite "blocktype":
  test "should hash equal non-leaf block addresses onto the same hash":
    let
      cid1 = Cid.example
      nonLeaf1 = BlockAddress.init(cid1)
      nonLeaf2 = BlockAddress.init(cid1)

    check nonLeaf1 == nonLeaf2
    check nonLeaf1.hash == nonLeaf2.hash

  test "should hash equal leaf block addresses onto the same hash":
    let
      cid1 = Cid.example
      leaf1 = BlockAddress.init(cid1, 0)
      leaf2 = BlockAddress.init(cid1, 0)

    check leaf1 == leaf2
    check leaf1.hash == leaf2.hash

  test "should hash different non-leaf block addresses onto different hashes":
    let
      cid1 = Cid.example
      cid2 = Cid.example
      nonLeaf1 = BlockAddress.init(cid1)
      nonLeaf2 = BlockAddress.init(cid2)

    check nonLeaf1 != nonLeaf2
    check nonLeaf1.hash != nonLeaf2.hash

  test "should hash different leaf block addresses onto different hashes":
    let
      cid1 = Cid.example
      leaf1 = BlockAddress.init(cid1, 0)
      leaf2 = BlockAddress.init(cid1, 1)

    check leaf1 != leaf2
    check leaf1.hash != leaf2.hash
