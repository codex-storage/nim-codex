{.push raises: [].}

import std/[options, net]
import results
import libplum/plum
import libplum/libplum

export plum, libplum, results, options, net

type NatStrategy* = enum
  NatAuto
