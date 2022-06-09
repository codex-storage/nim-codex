## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import por
import benchmark
import strutils

const sectorsperblock = 1024.int64
const querylen = 22

proc testbls() : bool =
  benchmark "Key generation":
    let (spk, ssk) = por.keygen()

  benchmark "Auth generation (s=" & $sectorsperblock & ")":
    let (tau, authenticators) = por.setup(ssk, sectorsperblock, "example.txt")
  echo "tau: ", tau
  echo "Auth: ", authenticators

  benchmark "Generating challenge (q=" & $querylen & ")":
    let q = por.generateQuery(tau, spk, querylen)
  echo "Generated!", "\nq:", q

  benchmark "Issuing proof":
    let (mu, sigma) = por.generateProof(q, authenticators, spk, sectorsperblock, "example.txt")
  echo "Issued!", "\nmu:", mu, "\nsigma:", sigma

  benchmark "Verifying proof":
    result = por.verifyProof(tau, q, mu, sigma, spk)
  echo "Result: ", result

let r = testbls()
