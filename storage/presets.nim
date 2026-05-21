# Presets are hard-coded configuration bundles that get compiled into code. They can refer
# to different things, but the canonical example are sets of bootstrap nodes that define
# logically different networks; e.g., "logos.dev" and "logos.test" refer to the Logos
# devnet and latest testnet, respectively.
import std/strutils

import pkg/chronicles
import pkg/codexdht/discv5/protocol
import pkg/libp2p/routing_record
import pkg/stew/base64

# A NetworkPreset is a set of bootstrap nodes (represented
# by their signed peer records) along with some description metadata.
type NetworkPreset* = object
  name*: string
  description*: string
  unparsedRecords: seq[string]

proc init*(
    T: type NetworkPreset, name: string, description: string, records: seq[string]
): T =
  result.name = name
  result.description = description

  # We have to delay parsing of records to runtime because
  # of https://github.com/nim-lang/Nim/issues/23468
  result.unparsedRecords = records

func `$`*(preset: NetworkPreset): string =
  "[" & preset.name & "]: " & preset.description

func `$`*[N](presets: array[N, NetworkPreset]): string =
  result = ""
  for preset in presets:
    result &= $preset & "; "

proc parse*(T: type SignedPeerRecord, p: string): Result[SignedPeerRecord, string] =
  var res: SignedPeerRecord
  try:
    if not res.fromURI(p):
      return err("The uri is not a valid SignedPeerRecord: " & p)
    return ok(res)
  except LPError, Base64Error:
    let e = getCurrentException()
    return err(e.msg)

proc `bootstrapNodes`*(self: NetworkPreset): seq[SignedPeerRecord] =
  for record in self.unparsedRecords:
    # Having an invalid SPR in a hardcoded config is a bug, and
    # it should crash the node.
    result.add(parse(SignedPeerRecord, record).tryGet())

const NetworkPresets* = [
  NetworkPreset.init(
    "logos.dev",
    "Logos devnet",
    @[
      "spr:CiUIAhIhAwfZDeTtWNlSgRbZlZfvxLI5Bpy0lFEYN7gImS3oHNaSEgIDARpJCicAJQgCEiEDB9kN5O1Y2VKBFtmVl-" &
        "_EsjkGnLSUURg3uAiZLegc1pIQ__O20AYaCwoJBBiQTsiRAiOCGgsKCQQYkE7IkQIjgipHMEUCIQCIZx-HlVsLXJLhD6SEV" &
        "x6Zt_1aG9IqMq-Luvz8No_J0wIgc8I9PRtheG4s5tzHjkEJMLcq3Jf09IT_FGkzPcJm8h4",
      "spr:CiUIAhIhA8d4LjRirtXO1M-JEmbhVA0CQeA7hHNR9BA7DvFsPKTEEgIDARpJCicAJQgCEiEDx3guNGKu1c7Uz4kSZu" &
        "FUDQJB4DuEc1H0EDsO8Ww8pMQQhPW20AYaCwoJBCIq5juRAiOCGgsKCQQiKuY7kQIjgipGMEQCIHV_8nJ0iedWjlAxUhBm" &
        "dAbDPLu5g2RmcnmJBD8cbD98AiAp1w9nAJgLlPIr41aMcdkds_eSoh8ImOVKvq6Idx-Ugg",
      "spr:CiUIAhIhA_MocWwn1_t__FEONMqYluUjc9ZVkcvYRLo6C0GzTkbfEgIDARpJCicAJQgCEiED8yhxbCfX-3_8UQ40yp" &
        "iW5SNz1lWRy9hEujoLQbNORt8QlfO20AYaCwoJBC_u5W-RAiOCGgsKCQQv7uVvkQIjgipGMEQCIHMpQO31gg4FoKYtDyTT" &
        "QS8xFz1KEmfqH385EeMUNbhPAiBblCkmOfQBmXj6eryaSiXWsftgohE-SPbKwsASZ1Zs3Q",
    ],
  ),
  NetworkPreset.init(
    "codex.dev",
    "Codex legacy devnet (deprecated)",
    @[
      "spr:CiUIAhIhA-VlcoiRm02KyIzrcTP-ljFpzTljfBRRKTIvhMIwqBqWEgIDARpJCicAJQgCEiED5WVyiJGbTYrIjOtxM_6" &
        "WMWnNOWN8FFEpMi-EwjCoGpYQs8n8wQYaCwoJBHTKubmRAnU6GgsKCQR0yrm5kQJ1OipHMEUCIQDwUNsfReB4ty7JFS" &
        "5WVQ6n1fcko89qVAOfQEHixa03rgIgan2-uFNDT-r4s9TOkLe9YBkCbsRWYCHGGVJ25rLj0QE",
      "spr:CiUIAhIhApIj9p6zJDRbw2NoCo-tj98Y760YbppRiEpGIE1yGaMzEgIDARpJCicAJQgCEiECkiP2nrMkNFvDY2gKj62P" &
        "3xjvrRhumlGISkYgTXIZozMQvcz8wQYaCwoJBAWhF3WRAnVEGgsKCQQFoRd1kQJ1RCpGMEQCIFZB84O_nzPNuViqEGRL" &
        "1vJTjHBJ-i5ZDgFL5XZxm4HAAiB8rbLHkUdFfWdiOmlencYVn0noSMRHzn4lJYoShuVzlw",
      "spr:CiUIAhIhApqRgeWRPSXocTS9RFkQmwTZRG-Cdt7UR2N7POoz606ZEgIDARpJCicAJQgCEiECmpGB5ZE9JehxNL1EWRCb" &
        "BNlEb4J23tRHY3s86jPrTpkQj8_8wQYaCwoJBAXfEfiRAnVOGgsKCQQF3xH4kQJ1TipGMEQCIGWJMsF57N1iIEQgTH7I" &
        "rVOgEgv0J2P2v3jvQr5Cjy-RAiAy4aiZ8QtyDvCfl_K_w6SyZ9csFGkRNTpirq_M_QNgKw",
    ],
  ),
]

proc `default`*(presets: openArray[NetworkPreset]): NetworkPreset =
  presets[0]

# Precomputes those as as consts so we can use them in nim-confutils CLI
# help strings.
const
  NetworkPresetsDescription* = $NetworkPresets
  DefaultNetworkPreset* = NetworkPresets.default

proc find*(presets: openArray[NetworkPreset], p: string): Option[NetworkPreset] =
  for preset in presets:
    if preset.name == p:
      return some(preset)
  return none(NetworkPreset)

proc findByPrefix*(presets: openArray[NetworkPreset], val: string): seq[string] =
  for p in presets:
    if p.name.startsWith(val):
      result.add p.name
