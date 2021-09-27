## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import bls
import benchmark
import strutils

const sectorsperblock = 1024.int64
const querylen = 22

proc testbls() : bool =
  benchmark "Key generation":
    let (spk, ssk) = bls.keygen()

  benchmark "Auth generation":
    let (tau, authenticators) = bls.setup(ssk, sectorsperblock, "example.txt")
  #echo "Auth: ", authenticators

  benchmark "Generating challenge...":
    let q = bls.generateQuery(tau, spk, querylen)
  #echo "Generated!" #, " q:", q

  benchmark "Issuing proof...":
    let (mu, sigma) = bls.generateProof(q, authenticators, spk, sectorsperblock, "example.txt")
  #echo "Issued!" #, " mu:", mu, " sigma:", sigma

  benchmark "Verifying proof...":
    result = bls.verifyProof(tau, q, mu, sigma, spk)
  echo "Result: ", result

let r = testbls()
