import std/macros
import pkg/questionable
import ./multinodes
import ./storageconfig
import ./storageprocess
import ./storageclient
import ./nodeconfigs

export storageclient
export multinodes

template twonodessuite*(name: string, body: untyped) =
  multinodesuite name:
    let twoNodesConfig {.inject, used.} =
      # Disable Autonat for this suite
      NodeConfigs(
        clients: StorageConfigs.init(nodes = 2).withExtIp(1).withAutonatServer(0).some
      )

    var node1 {.inject, used.}: StorageProcess
    var node2 {.inject, used.}: StorageProcess
    var client1 {.inject, used.}: StorageClient
    var client2 {.inject, used.}: StorageClient

    setup:
      node1 = clients()[0]
      node2 = clients()[1]

      client1 = node1.client
      client2 = node2.client

    body
