import std/json
import pkg/asynctest
import pkg/ethers

# Allow multiple setups and teardowns in a test suite
template multisetup =

  var setups: seq[proc: Future[void] {.gcsafe.}]
  var teardowns: seq[proc: Future[void] {.gcsafe.}]

  setup:
    for setup in setups:
      await setup()

  teardown:
    for teardown in teardowns:
      await teardown()

  template setup(setupBody) {.inject.} =
    setups.add(proc {.async.} = setupBody)

  template teardown(teardownBody) {.inject.} =
    teardowns.insert(proc {.async.} = teardownBody)

## Unit testing suite that sets up an Ethereum testing environment.
## Injects a `provider` instance, and a list of `accounts`.
## Calls the `evm_snapshot` and `evm_revert` methods to ensure that any
## changes to the blockchain do not persist.
template ethersuite*(name, body) =
  suite name:

    var provider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode

    multisetup()

    setup:
      provider = JsonRpcProvider.new("ws://localhost:8545")
      snapshot = await send(provider, "evm_snapshot")
      accounts = await provider.listAccounts()

    teardown:
      discard await send(provider, "evm_revert", @[snapshot])

    body

export asynctest
export ethers
