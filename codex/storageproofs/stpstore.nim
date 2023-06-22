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

import ../errors
import ../formats

import ./stpproto
import ./por

type
  StpStore* = object
    authDir*: string
    postfixLen*: int

template stpPath*(self: StpStore, cid: Cid): string =
  self.authDir / ($cid)[^self.postfixLen..^1] / $cid

proc retrieve*(
  self: StpStore,
  cid: Cid
): Future[?!PorMessage] {.async.} =
  ## Retrieve authenticators from data store
  ##

  let path = self.stpPath(cid) / "por"
  var data: seq[byte]
  if (
    let res = io2.readFile(path, data);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Cannot retrieve storage proof data from fs", path , error
    return failure("Cannot retrieve storage proof data from fs")

  return PorMessage.decode(data).mapFailure

proc store*(
  self: StpStore,
  por: PorMessage,
  cid: Cid
): Future[?!void] {.async.} =
  ## Persist storage proofs
  ##

  let
    dir = self.stpPath(cid)

  if io2.createPath(dir).isErr:
    trace "Unable to create storage proofs prefix dir", dir
    return failure(&"Unable to create storage proofs prefix dir ${dir}")

  let path = dir / "por"
  if (
    let res = io2.writeFile(path, por.encode());
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to store storage proofs", path, cid, error
    return failure(
      &"Unable to store storage proofs - path = ${path} cid = ${cid} error = ${error}")

  return success()

proc retrieve*(
    self: StpStore,
    cid: Cid,
    blocks: seq[int]
): Future[?!seq[Tag]] {.async.} =
  var tags: seq[Tag]
  for b in blocks:
    var tag = Tag(idx: b)
    let path = self.stpPath(cid) / $b
    if (
      let res = io2.readFile(path, tag.tag);
      res.isErr):
      let error = io2.ioErrorMsg(res.error)
      trace "Cannot retrieve tags from fs", path , error
      return failure("Cannot retrieve tags from fs")
    tags.add(tag)

  return tags.success

proc store*(
    self: StpStore,
    tags: seq[Tag],
    cid: Cid
): Future[?!void] {.async.} =
  let
    dir = self.stpPath(cid)

  if io2.createPath(dir).isErr:
    trace "Unable to create storage proofs prefix dir", dir
    return failure(&"Unable to create storage proofs prefix dir ${dir}")

  for t in tags:
    let path = dir / $t.idx
    if (
      let res = io2.writeFile(path, t.tag);
      res.isErr):
      let error = io2.ioErrorMsg(res.error)
      trace "Unable to store tags", path, cid, error
      return failure(
        &"Unable to store tags - path = ${path} cid = ${cid} error = ${error}")

  return success()

proc init*(
  T: type StpStore,
  authDir: string,
  postfixLen: int = 2
): StpStore =
  ## Init StpStore
  ## 
  StpStore(
    authDir: authDir,
    postfixLen: postfixLen)
