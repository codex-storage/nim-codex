import std/sugar
import std/sequtils

import pkg/unittest2
import pkg/libp2p

import pkg/dagger/blockexchange/peers
import pkg/dagger/blockexchange/protobuf/blockexc

import ../examples

suite "Peer Context Store":
  var
    store: PeerCtxStore
    peerCtx: BlockExcPeerCtx

  setup:
    store = PeerCtxStore.new()
    peerCtx = BlockExcPeerCtx.example
    store.add(peerCtx)

  test "Should add peer":
    check peerCtx.id in store

  test "Should remove peer":
    store.remove(peerCtx.id)
    check peerCtx.id notin store

  test "Should get peer":
    check store.get(peerCtx.id) == peerCtx

suite "Peer Context Store Peer Selection":
  var
    store: PeerCtxStore
    peerCtxs: seq[BlockExcPeerCtx]
    cids: seq[Cid]

  setup:
    store = PeerCtxStore.new()
    cids = collect(newSeq):
      for i in 0..<10: Cid.example

    peerCtxs = collect(newSeq):
      for i in 0..<10: BlockExcPeerCtx.example

    for p in peerCtxs:
      store.add(p)

  teardown:
    store = nil
    cids = @[]
    peerCtxs = @[]

  test "Should select peers that have Cid":
    peerCtxs[0].peerPrices = collect(initTable):
      for i, c in cids:
        { c: i.u256 }

    peerCtxs[5].peerPrices = collect(initTable):
      for i, c in cids:
        { c: i.u256 }

    let
      peers = store.peersHave(cids[0])

    check peers.len == 2
    check peerCtxs[0] in peers
    check peerCtxs[5] in peers

  test "Should select cheapest peers for Cid":
    peerCtxs[0].peerPrices = collect(initTable):
      for i, c in cids:
        { c: (5 + i).u256 }

    peerCtxs[5].peerPrices = collect(initTable):
      for i, c in cids:
        { c: (2 + i).u256 }

    peerCtxs[9].peerPrices = collect(initTable):
      for i, c in cids:
        { c: i.u256 }

    let
      peers = store.selectCheapest(cids[0])

    check peers.len == 3
    check peers[0] == peerCtxs[9]
    check peers[1] == peerCtxs[5]
    check peers[2] == peerCtxs[0]

  test "Should select peers that want Cid":
    let
      entries = cids.mapIt(
        Entry(
          `block`: it.data.buffer,
          priority: 1,
          cancel: false,
          wantType: WantType.wantBlock,
          sendDontHave: false))

    peerCtxs[0].peerWants = entries
    peerCtxs[5].peerWants = entries

    let
      peers = store.peersWant(cids[4])

    check peers.len == 2
    check peerCtxs[0] in peers
    check peerCtxs[5] in peers
