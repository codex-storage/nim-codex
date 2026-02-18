import pkg/unittest2
import pkg/libp2p/cid

import pkg/storage/blocktype

import ./examples

suite "Blocktype":
  test "should hash equal block addresses onto the same hash":
    let
      cid1 = Cid.example
      addr1 = BlockAddress.init(cid1, 0)
      addr2 = BlockAddress.init(cid1, 0)

    check addr1 == addr2
    check addr1.hash == addr2.hash

  test "should hash different block addresses onto different hashes":
    let
      cid1 = Cid.example
      addr1 = BlockAddress.init(cid1, 0)
      addr2 = BlockAddress.init(cid1, 1)

    check addr1 != addr2
    check addr1.hash != addr2.hash
