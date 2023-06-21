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

import ../stores

type
  Backend* = ref object of RootObj
    blockSize*: int # block size in bytes
    buffers*: int   # number of original pieces
    parity*: int    # number of redundancy pieces

  EncoderBackend* = ref object of Backend
  DecoderBackend* = ref object of Backend

method release*(self: Backend) {.base.} =
  ## release the backend
  ## 
  raiseAssert("not implemented!")

method encode*(
    self: EncoderBackend,
    buffers,
    parity: var openArray[seq[byte]]
): Result[void, cstring] {.base.} =
  ## encode buffers using a backend
  ## 
  raiseAssert("not implemented!")

method decode*(
    self: DecoderBackend,
    buffers,
    parity,
    recovered: var openArray[seq[byte]]
): Result[void, cstring] {.base.} =
  ## decode buffers using a backend
  ## 
  raiseAssert("not implemented!")
