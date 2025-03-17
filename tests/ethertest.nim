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
    var ethProvider {.inject, used.} = JsonRpcProvider.new("ws://localhost:8545")
    var accounts {.inject, used.} = waitFor ethProvider.listAccounts()
    var snapshot: JsonNode

    setup:
      snapshot = await send(ethProvider, "evm_snapshot")

    teardown:
      discard await send(ethProvider, "evm_revert", @[snapshot])

    body

    waitFor ethProvider.close()

export asynctest
export ethers except `%`
