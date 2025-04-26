## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p/cid
import ../utils/json

type DirectoryManifest* = ref object
  name* {.serialize.}: string
  cids* {.serialize.}: seq[Cid]

proc `$`*(self: DirectoryManifest): string =
  "DirectoryManifest(name: " & self.name & ", cids: " & $self.cids & ")"

func `==`*(a: DirectoryManifest, b: DirectoryManifest): bool =
  a.name == b.name and a.cids == b.cids

proc newDirectoryManifest*(name: string, cids: seq[Cid]): DirectoryManifest =
  DirectoryManifest(name: name, cids: cids)
