## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import ../stores

type
  ProverBackend* = ref object of RootObj

  ProofBackend* = ref object of Backend
  VerifyBackend* = ref object of Backend

method release*(self: ProverBackend) {.base.} =
  ## release the backend
  ##

  raiseAssert("not implemented!")

method prove*(
    self: ProofBackend,
    indicies,
    payload: var openArray[seq[byte]]
): Result[void, cstring] {.base.} =
  ## encode buffers using a backend
  ##

  raiseAssert("not implemented!")

method verify*(
    self: VerifyBackend,
    buffers,
    parity,
    recovered: var openArray[seq[byte]]
): Result[void, cstring] {.base.} =
  ## decode buffers using a backend
  ##

  raiseAssert("not implemented!")
