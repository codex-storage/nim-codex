## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ../manifest
import ../stores

type
  Backend* = object of RootObj
    blockSize*: int # block size in bytes
    K*: int         # number of original pieces
    M*: int         # number of redundancy pieces


