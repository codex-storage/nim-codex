import std/json
import std/sequtils
import pkg/chronos
import pkg/questionable/results

import ./multinodes
import ./storageclient
import ./storageconfig

const
  RelayTimeout* = 30_000
  PollInterval* = 1_000

proc checkNatStatus*(
    client: StorageClient, reachability: string, relayRunning: bool, clientMode: bool
) {.async.} =
  check eventuallySafe(
    block:
      let info = (await client.info()).get
      let nat = info["nat"]
      let addrs = info["addrs"].getElems.mapIt(it.getStr)
      nat["reachability"].getStr() == reachability and
        nat["clientMode"].getBool() == clientMode and
        nat["relayRunning"].getBool() == relayRunning and
        addrs.anyIt("p2p-circuit" in it) == relayRunning,
    timeout = RelayTimeout,
    pollInterval = PollInterval,
  )

proc checkNatStatus*(client: StorageClient, reachability: string) {.async.} =
  let notReachable = reachability == "NotReachable"
  await client.checkNatStatus(
    reachability, relayRunning = notReachable, clientMode = notReachable
  )
