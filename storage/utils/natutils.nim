{.push raises: [].}

import std/[options, net]
import pkg/chronicles
import results
import libplum/plum
import libplum/libplum

export plum, libplum, results, options, net

logScope:
  topics = "nat"

type NatStrategy* = enum
  NatAuto
