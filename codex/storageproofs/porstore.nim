## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os
import std/strformat

import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/stew/io2
import pkg/questionable
import pkg/questionable/results
import pkg/protobuf_serialization

import ./por

type
  PorStore* = object
    authDir*: string
    postfixLen*: int

template authPath*(self: PorStore, cid: Cid): string =
  self.authDir / ($cid)[^self.postfixLen..^1] / $cid

proc retrieve*(
  self: PorStore,
  cid: Cid): Future[?!PorMessage] {.async.} =
  ## Retrieve authenticators from data store
  ##

  let path = self.authPath(cid)
  var data: seq[byte]
  if (
    let res = io2.readFile(path, data);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Cannot retrieve authenticators from fs", path , error
    return failure("Cannot retrieve authenticators from fs")

  return Protobuf.decode(data, PorMessage).success

proc store*(
  self: PorStore,
  por: PoR,
  cid: Cid): Future[?!void] {.async.} =
  ## Persist storage proofs
  ##

  let
    dir = self.authPath(cid).parentDir

  if io2.createPath(dir).isErr:
    trace "Unable to create storage proofs prefix dir", dir
    return failure(&"Unable to create storage proofs prefix dir ${dir}")

  let path = self.authPath(cid)
  if (
    let res = io2.writeFile(path, Protobuf.encode(por.toMessage()));
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to store storage proofs", path, cid = cid, error
    return failure(
      &"Unable to store storage proofs path = ${path} cid = ${$cid} error = ${error}")

  return success()

proc init*(
  T: type PorStore,
  authDir: string,
  postfixLen: int = 2): PorStore =
  T(
    authDir: authDir,
    postfixLen: postfixLen)
