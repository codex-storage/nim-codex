## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos

import ../manifest
import ../stores

import ./backend

export backend

type
  BackendProvider* = proc(size, buffers, parity: int): Backend
    {.raises: [Defect], noSideEffect.}

  Erasure* = ref object
    provider*: BackendProvider
    

proc encode*(
  self: Erasure,
  manifest: Manifest,
  store: BlockStore) {.async.} =
  discard

proc decode*(
  self: Erasure,
  manifest: Manifest,
  store: BlockStore) {.async.} =
  discard

proc start() {.async.} =

proc new*(T: type Erasure, provider: BackendProvider): Erasure =
  Erasure(provider: BackendProvider)
