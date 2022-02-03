import std/sequtils

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/nitro/wallet

import pkg/dagger/stores
import pkg/dagger/blockexchange
import pkg/dagger/blocktype as bt

import ../examples

proc generateNodes*(
  num: Natural,
  blocks: openArray[bt.Block] = [],
  secureManagers: openarray[SecureProtocol] = [
    SecureProtocol.Noise,
  ]): seq[tuple[switch: Switch, blockexc: BlockExcEngine]] =
  for i in 0..<num:
    let
      switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
      wallet = WalletRef.example
      network = BlockExcNetwork.new(switch)
      localStore: BlockStore = MemoryStore.new(blocks.mapIt( it ))
      blockStoreMgr = BlockStoreManager.new(@[localStore])
      engine = BlockExcEngine.new(wallet, network, blockStoreMgr)

    switch.mount(network)

    # initialize our want lists
    engine.wantList = blocks.mapIt( it.cid )
    switch.mount(network)
    result.add((switch, engine))

proc connectNodes*(nodes: seq[Switch]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo.peerId, node.peerInfo.addrs)
