## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises
push: {.upraises: [].}

import std/sequtils

template batchIt*[T](elms: openArray[T], batchSize: int, body: untyped) =
  let
    batches =
      (elms.len div batchSize) +
      (if (elms.len mod batchSize) > 0: 1 else: 0)

  trace "Splitting requests into batches", elements = elms.len, batches = batches, size = batchSize
  for it {.inject.} in elms.distribute(max(1, batches), spread = false):
    block:
      body
