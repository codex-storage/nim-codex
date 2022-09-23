## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/strutils

import pkg/chronicles
import pkg/libp2p

func shortLog*(cid: Cid): string =
  ## Returns compact string representation of ``pid``.
  var scid = $cid
  if len(scid) > 10:
    scid[3] = '*'

    when (NimMajor, NimMinor) > (1, 4):
      scid.delete(4 .. scid.high - 6)
    else:
      scid.delete(4, scid.high - 6)

  scid

chronicles.formatIt(Cid): shortLog(it)
