## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.


## Timer
## Used to execute a callback in a loop or one-shot

type 
  Timer* = ref object

method start*(timer: Timer, callback: Proc, interval: int) =
  callback()
