## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/questionable
import pkg/questionable/results
import ./blocktype

export blocktype

type
  BlockStreamRef* = ref object of RootObj

method nextBlock*(b: BlockStreamRef): ?!Block {.base.} =
  doAssert(false, "Not implemented!")

iterator items*(b: BlockStreamRef): Block =
  while true:
    without blk =? b.nextBlock():
      break

    yield blk
