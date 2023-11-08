import pkg/asynctest
import pkg/ethers

import ./checktest

## Unit testing suite that sets up an Ethereum testing environment.
## Injects an `ethProvider` instance, and a list of `accounts`.
## Calls the `evm_snapshot` and `evm_revert` methods to ensure that any
## changes to the blockchain do not persist.
template ethersuite*(name, body) =
  asyncchecksuite name:

    # NOTE: `ethProvider` cannot be named `provider`, as there is an unknown
    # conflict that is occurring within JsonRpcProvider in which the compiler cannot
    # understand the `provider` symbol type when several layers of nested templates
    # are involved, eg ethertest > multinodesuite > marketplacesuite > test
    var ethProvider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode

    setup:
      ethProvider = JsonRpcProvider.new("ws://localhost:8545")
      snapshot = await send(ethProvider, "evm_snapshot")
      accounts = await ethProvider.listAccounts()

    teardown:
      discard await send(ethProvider, "evm_revert", @[snapshot])

    body

export asynctest
export ethers except `%`
