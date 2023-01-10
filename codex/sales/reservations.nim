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

import pkg/datastore
import ../stores

type
  Reservations* = object
    repoStore: RepoStore
    dataStore: Datastore

proc new*(_: type Reservations, repo: RepoStore, data: Datastore): Reservations =
  let r = Reservations(repoStore: repo, dataStore: data)
  return r

proc isAvailable(self: Reservations): Future[bool] {.async.} =
  # TODO: query RepoStore
  return true

proc reserve*(self: Reservations, bytes: uint): Future[?!void] {.async.} =
  return self.repoStore.reserve(bytes)