# import std/json
import pkg/asynctest
import pkg/ethers

import ./checktest

## Unit testing suite that sets up an Ethereum testing environment.
## Injects a `provider` instance, and a list of `accounts`.
## Calls the `evm_snapshot` and `evm_revert` methods to ensure that any
## changes to the blockchain do not persist.
template ethersuite*(name, body) =
  asyncchecksuite name:

    var provider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode

    setup:
      provider = JsonRpcProvider.new("ws://localhost:8545")
      snapshot = await send(provider, "evm_snapshot")
      accounts = await provider.listAccounts()

    teardown:
      discard await send(provider, "evm_revert", @[snapshot])

    body

export asynctest
export ethers except `%`
