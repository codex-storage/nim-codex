## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines Manifest and all related types

import std/tables
import pkg/libp2p

import ../units
export units

const
  BlockCodec* = multiCodec("raw")
  DagPBCodec* = multiCodec("dag-pb")

type
  ManifestCoderType*[codec: static MultiCodec] = object
  DagPBCoder* = ManifestCoderType[multiCodec("dag-pb")]

const
  ManifestContainers* = {
    $DagPBCodec: DagPBCoder()
  }.toTable
