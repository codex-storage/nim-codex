import std/sequtils

import pkg/chronos
import pkg/libp2p

import pkg/dagger/stores
import pkg/dagger/blocktype as bt

import ../examples

proc generateNodes*(
  num: Natural,
  blocks: openArray[bt.Block] = [],
  secureManagers: openarray[SecureProtocol] = [
    SecureProtocol.Noise,
  ]): seq[tuple[switch: Switch, blockexc: NetworkStore]] =
  for i in 0..<num:
    let
      switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
      wallet = WalletRef.example
      network = BlockExcNetwork.new(switch)
      blockexc = NetworkStore.new(MemoryStore.new(blocks), wallet, network)

    switch.mount(network)

    # initialize our want lists
    blockexc.engine.wantList = blocks.mapIt( it.cid )
    switch.mount(network)
    result.add((switch, blockexc))

proc connectNodes*(nodes: seq[Switch]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo.peerId, node.peerInfo.addrs)
