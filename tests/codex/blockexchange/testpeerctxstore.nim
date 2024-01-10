import std/sugar
import std/sequtils
import std/unittest

import pkg/libp2p

import pkg/codex/blockexchange/peers
import pkg/codex/blockexchange/protobuf/blockexc
import pkg/codex/blockexchange/protobuf/presence

import ../helpers
import ../examples

checksuite "Peer Context Store":
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

checksuite "Peer Context Store Peer Selection":
  var
    store: PeerCtxStore
    peerCtxs: seq[BlockExcPeerCtx]
    addresses: seq[BlockAddress]

  setup:
    store = PeerCtxStore.new()
    addresses = collect(newSeq):
      for i in 0..<10: BlockAddress(leaf: false, cid: Cid.example)

    peerCtxs = collect(newSeq):
      for i in 0..<10: BlockExcPeerCtx.example

    for p in peerCtxs:
      store.add(p)

  teardown:
    store = nil
    addresses = @[]
    peerCtxs = @[]

  test "Should select peers that have Cid":
    peerCtxs[0].blocks = collect(initTable):
      for i, a in addresses:
        { a: Presence(address: a, price: i.u256) }

    peerCtxs[5].blocks = collect(initTable):
      for i, a in addresses:
        { a: Presence(address: a, price: i.u256) }

    let
      peers = store.peersHave(addresses[0])

    check peers.len == 2
    check peerCtxs[0] in peers
    check peerCtxs[5] in peers

  test "Should select cheapest peers for Cid":
    peerCtxs[0].blocks = collect(initTable):
      for i, a in addresses:
        { a: Presence(address: a, price: (5 + i).u256) }

    peerCtxs[5].blocks = collect(initTable):
      for i, a in addresses:
        { a: Presence(address: a, price: (2 + i).u256) }

    peerCtxs[9].blocks = collect(initTable):
      for i, a in addresses:
        { a: Presence(address: a, price: i.u256) }

    let
      peers = store.selectCheapest(addresses[0])

    check peers.len == 3
    check peers[0] == peerCtxs[9]
    check peers[1] == peerCtxs[5]
    check peers[2] == peerCtxs[0]

  test "Should select peers that want Cid":
    let
      entries = addresses.mapIt(
        WantListEntry(
          address: it,
          priority: 1,
          cancel: false,
          wantType: WantType.WantBlock,
          sendDontHave: false))

    peerCtxs[0].peerWants = entries
    peerCtxs[5].peerWants = entries

    let
      peers = store.peersWant(addresses[4])

    check peers.len == 2
    check peerCtxs[0] in peers
    check peerCtxs[5] in peers
