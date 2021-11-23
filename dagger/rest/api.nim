## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p

import ../node

proc validate(
  pattern: string,
  value: string): int {.gcsafe, raises: [Defect].} =
  0

proc encodeString(cid: type Cid): Result[string, cstring] =
  ok($cid)

proc decodeString(T: type Cid, value: string): Result[Cid, cstring] =
  let cid = Cid.init(value)
  if cid.isOk:
    ok(cid.get())
  else:
    case cid.error
    of CidError.Incorrect: err("Incorrect Cid")
    of CidError.Unsupported: err("Unsupported Cid")
    of CidError.Overrun: err("Overrun Cid")
    else: err("Error parsing Cid")

proc initRestApi*(node: DaggerNodeRef): RestRouter =
  var router = RestRouter.init(validate)
  router.api(
    MethodGet,
    "/api/dagger/v1/download/{id}") do (id: Cid) -> RestApiResponse:
      echo $id
      return RestApiResponse.response("")

  router
