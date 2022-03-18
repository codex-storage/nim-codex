## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ./por
import benchmark
import strutils

const sectorsperblock = 1024.int64
const querylen = 22

proc testbls() : bool =
  benchmark "Key generation":
    let
      file = open("/Users/dryajov/Downloads/20181126_152327_bak.mp4")
      por = BLSPoR.init()

  benchmark "Auth generation (s=" & $sectorsperblock & ")":
    let
      (tau, authenticators) = por.setup(sectorsperblock, file)

  #echo "Auth: ", authenticators

  benchmark "Generating challenge (q=" & $querylen & ")":
    let q = por.generateQuery(tau, querylen)
  #echo "Generated!" #, " q:", q

  benchmark "Issuing proof":
    file.setFilePos(0)
    let (mu, sigma) = por.generateProof(q, authenticators, sectorsperblock, file)

  #echo "Issued!" #, " mu:", mu, " sigma:", sigma

  benchmark "Verifying proof":
    result = por.verifyProof(tau, q, mu, sigma)

  echo "Result: ", result
  file.close()

let r = testbls()
