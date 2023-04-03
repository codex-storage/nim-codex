import pkg/ethers
import ../clock
import ../marketplace
import ../market

type
  ContractInteractions* = ref object of RootObj
    clock: OnChainClock

proc new*(T: type ContractInteractions,
          clock: OnChainClock): T =
  T(clock: clock)

proc prepare*(
  providerUrl: string = "ws://localhost:8545",
  account, contractAddress: Address):
  ?!tuple[contract: Marketplace, market: OnChainMarket, clock: OnChainClock] =

  let provider = JsonRpcProvider.new(providerUrl)
  let signer = provider.getSigner(account)

  let contract = Marketplace.new(contractAddress, signer)
  let market = OnChainMarket.new(contract)
  let clock = OnChainClock.new(signer.provider)

  return success((contract, market, clock))

method start*(self: ContractInteractions) {.async, base.} =
  await self.clock.start()

method stop*(self: ContractInteractions) {.async, base.} =
  await self.clock.stop()
