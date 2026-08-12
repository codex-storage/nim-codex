import std/json
import std/sequtils

import pkg/questionable/results

import ../multinodes

multinodesuite "peer addresses":
  test "should not set peer address to listen address when extip is specified",
    NodeConfigs(clients: StorageConfigs
        .init(nodes = 2)
        .withExtIp(1, ip = "7.7.7.2")
        .withListenPort(1, 40401)
        .debug(1, true).some
    ):

    let info = (await clients()[1].client.info()).get
    check info["addrs"] == %*["/ip4/7.7.7.2/tcp/40401"]
