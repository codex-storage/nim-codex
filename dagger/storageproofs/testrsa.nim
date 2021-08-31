## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pos
import random

proc testrsa() : bool =
  let (spk, ssk) = pos.rsaKeygen()
  echo "Key generated!"

  let (tau, authenticators) = pos.st(ssk, "example.txt")
  echo "Signed!"
  echo "Auth: ", authenticators

  echo "Generating challenge..."
  let q = pos.generateQuery(tau, spk)
  echo "Generated!", " q:", q

  echo "Issuing proof..."
  let (mu, sigma) = pos.generateProof(q, authenticators, spk, "example.txt")
  echo "Issued!", " mu:", mu, " sigma:", sigma

  echo "Verifying proof..."
  result = pos.verifyProof(tau, q, mu, sigma, spk)
  echo "Result: ", result

randomize()
let r = testrsa()
