## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/questionable/results

import ../../stores
import ../types

type
  ProverBackend*[H, P] = ref object of RootObj

  ProofBackend*[H, P] = ref object of ProverBackend[H, P]
  VerifyBackend*[H, P] = ref object of ProverBackend[H, P]

method release*[H, P](self: ProverBackend[H, P]) {.base.} =
  ## release the backend
  ##

  raiseAssert("not implemented!")

method prove*[H, P](
  self: ProofBackend[H, P],
  input: ProofInput[H, P]): Future[?!seq[byte]] {.base, async.} =
  ## prove the input using a backend
  ##

  raiseAssert("not implemented!")

method verify*[H, P](
  self: VerifyBackend[H, P],
  proof: sink seq[seq[byte]]): Future[?!bool] {.base, async.} =
  ## verify the proof using a backend
  ##

  raiseAssert("not implemented!")
