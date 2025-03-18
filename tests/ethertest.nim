import std/json
import pkg/ethers
import pkg/chronos

import ./asynctest
import ./checktest

## Unit testing suite that sets up an Ethereum testing environment.
## Injects a `ethProvider` instance, and a list of `accounts`.
## Calls the `evm_snapshot` and `evm_revert` methods to ensure that any
## changes to the blockchain do not persist.
template ethersuite*(name, body) =
  asyncchecksuite name:
    var ethProvider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode
    var fut: Future[void]

    proc resubscribeOnTimeout() {.async.} =
      while true:
        await sleepAsync(5.int64.minutes)
        #await ethProvider.resubscribeAll()

    setup:
      ethProvider = JsonRpcProvider.new("ws://localhost:8545")
      snapshot = await send(ethProvider, "evm_snapshot")
      accounts = await ethProvider.listAccounts()

      fut = resubscribeOnTimeout()
    teardown:
      if not fut.isNil:
        await fut.cancelAndWait()

      discard await send(ethProvider, "evm_revert", @[snapshot])

      await ethProvider.close()
    body

export asynctest
export ethers except `%`
