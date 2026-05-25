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
  NatScheduleInterval* = 5.seconds

proc checkNatStatus*(
    client: StorageClient, reachability: string, relayRunning: bool, clientMode: bool
) {.async.} =
  check eventuallySafe(
    block:
      let info = (await client.info()).get
      let nat = info["nat"]
      let addrs = info["addrs"].getElems.mapIt(it.getStr)
      let r = nat["reachability"].getStr()
      let cm = nat["clientMode"].getBool()
      let rr = nat["relayRunning"].getBool()
      let ha = addrs.anyIt("p2p-circuit" in it)
      let pm = nat["portMapping"].getStr()

      # It is important to check all the conditions together to avoid race
      # (new autonat iteration)
      # So we add a checkoint for better debug in case of failures
      checkpoint(
        "reachability=" & r & " (want " & reachability & ")" & " clientMode=" & $cm &
          " (want " & $clientMode & ")" & " relayRunning=" & $rr & " (want " &
          $relayRunning & ")" & " p2p-circuit=" & $ha & " (want " & $relayRunning & ")" &
          " portMapping=" & pm
      )
      r == reachability and cm == clientMode and rr == relayRunning and
        ha == relayRunning,
    timeout = RelayTimeout,
    pollInterval = PollInterval,
  )

proc checkReachable*(client: StorageClient) {.async.} =
  await client.checkNatStatus("Reachable", relayRunning = false, clientMode = false)

# Relay might be false when the mapping has been created for UPnP / TCP but
# Autonat didn't detect yet Reachable
proc checkNotReachable*(client: StorageClient, relayRunning = true) {.async.} =
  await client.checkNatStatus(
    "NotReachable", relayRunning = relayRunning, clientMode = true
  )
