import std/sequtils

import pkg/chronos
import pkg/libp2p

import pkg/dagger/discovery
import pkg/dagger/stores
import pkg/dagger/blocktype as bt
import pkg/dagger/blockexchange

import ../examples

type
  NodesComponents* = tuple[
    switch: Switch,
    blockDiscovery: Discovery,
    wallet: WalletRef,
    network: BlockExcNetwork,
    localStore: BlockStore,
    peerStore: PeerCtxStore,
    pendingBlocks: PendingBlocksManager,
    discovery: DiscoveryEngine,
    engine: BlockExcEngine,
    networkStore: NetworkStore]

proc generateNodes*(
  num: Natural,
  blocks: openArray[bt.Block] = []): seq[NodesComponents] =
  for i in 0..<num:
    let
      switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
      blockDiscovery = Discovery.new(switch.peerInfo, Port(0))
      wallet = WalletRef.example
      network = BlockExcNetwork.new(switch)
      localStore = CacheStore.new(blocks.mapIt( it ))
      peerStore = PeerCtxStore.new()
      pendingBlocks = PendingBlocksManager.new()
      discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
      engine = BlockExcEngine.new(localStore, wallet, network, discovery, peerStore, pendingBlocks)
      networkStore = NetworkStore.new(engine, localStore)

    switch.mount(network)
    result.add((
      switch,
      blockDiscovery,
      wallet,
      network,
      localStore,
      peerStore,
      pendingBlocks,
      discovery,
      engine,
      networkStore))

proc connectNodes*(nodes: seq[Switch]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo.peerId, node.peerInfo.addrs)
