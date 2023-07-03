## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
## 

import ./utils/asyncheapqueue
import ./utils/fileutils

export asyncheapqueue, fileutils


func divUp*[T: SomeInteger](a, b : T): T =
  ## Division with result rounded up (rather than truncated as in 'div')
  assert(b != T(0))
  if a==T(0): T(0) else: ((a - T(1)) div b) + T(1)

func roundUp*[T](a, b : T): T =
  ## Round up 'a' to the next value divisible by 'b'
  divUp(a,b) * b

