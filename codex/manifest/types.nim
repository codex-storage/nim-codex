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
import pkg/constantine/math/io/io_fields
import pkg/poseidon2

import ../units
export units
export curves # workaround for "undeclared identifier: 'getCurveOrder'" from constantine

const
  BlockCodec* = multiCodec("raw")
  DagPBCodec* = multiCodec("dag-pb")

type
  ManifestCoderType*[codec: static MultiCodec] = object
  DagPBCoder* = ManifestCoderType[multiCodec("dag-pb")]
  VerificationHash* = F

const
  ManifestContainers* = {
    $DagPBCodec: DagPBCoder()
  }.toTable

proc `==`*(a, b: VerificationHash): bool =
  a.toHex() == b.toHex()

proc fromInt*(T: type VerificationHash, value: SomeInteger | SomeUnsignedInt): VerificationHash =
  toF(value)

proc encode*(a: VerificationHash): string =
  a.toHex()

proc decode*(T: type VerificationHash, str: string): VerificationHash =
  F.fromHex(str)
