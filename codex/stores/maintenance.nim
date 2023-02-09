## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.


## Store maintenance module
## Looks for and removes expired blocks from blockstores.

type 
    BlockMaintainer* = ref object of RootObj
    BlockStoreChecker = ref object of RootObj

func start(stores[]):
    while true:
        sleep(interval)
        let repo = stores[index]
        process (repo)
        if processDone:
            inc loop index

func process(repo):
    for 0 -> 100:
        blockiter.GetNext
        processBlock(block)
        if iter finished:
            return allDone!
        return notDone

func processBlock(block):
    checkExpirey(block)

