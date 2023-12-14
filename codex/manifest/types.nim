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

import ../blocktype

type
  ManifestCoderTypeHolder*[codec: static MultiCodec] = object
  ManifestCoderType* = ManifestCoderTypeHolder[ManifestCodec]

const
  ManifestContainers* = {
    $ManifestCodec: ManifestCoderType()
  }.toTable
