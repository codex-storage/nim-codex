import std/algorithm
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
      let aa = info["announceAddresses"].getElems.mapIt(it.getStr)

      # Reachable nodes must announce their dialable (non-circuit) addrs to
      # the DHT (peerInfo observer); relayed nodes must announce their
      # circuit addrs (onReservation).
      let announceOk =
        if reachability == "Reachable":
          aa.len > 0 and aa.sorted == addrs.filterIt("p2p-circuit" notin it).sorted
        elif relayRunning:
          aa.len > 0 and aa.allIt("p2p-circuit" in it)
        else:
          true

      # It is important to check all the conditions together to avoid race
      # (new autonat iteration)
      # So we add a checkoint for better debug in case of failures
      checkpoint(
        "reachability=" & r & " (want " & reachability & ")" & " clientMode=" & $cm &
          " (want " & $clientMode & ")" & " relayRunning=" & $rr & " (want " &
          $relayRunning & ")" & " p2p-circuit=" & $ha & " (want " & $relayRunning & ")" &
          " portMapping=" & pm & " announceAddresses=" & $aa
      )
      r == reachability and cm == clientMode and rr == relayRunning and
        ha == relayRunning and announceOk,
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
