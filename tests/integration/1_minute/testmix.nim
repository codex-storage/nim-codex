import std/json

import ../multinodes

multinodesuite "Mix startup":
  test "a nat:auto node starts with Mix enabled",
    NodeConfigs(clients: StorageConfigs.init(nodes = 2).withMixEnabled().some):
    let info = (await clients()[1].client.info()).get

    check info["mixPubKey"].getStr().len > 0
