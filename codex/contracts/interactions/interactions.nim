import pkg/ethers
import ../../errors
import ../deployment
import ../clock
import ../marketplace
import ../market

type
  ContractInteractions* = ref object of RootObj
    clock: OnChainClock
  ContractInteractionsError* = object of CodexError
  ReadDeploymentFileFailureError* = object of ContractInteractionsError
  ContractAddressError* = object of ContractInteractionsError

proc new*(T: type ContractInteractions,
          clock: OnChainClock): T =
  T(clock: clock)

proc prepare*(
  signer: Signer,
  deployment: Deployment):
  ?!tuple[contract: Marketplace, market: OnChainMarket, clock: OnChainClock] =

  without address =? deployment.address(Marketplace):
    let err = newException(ContractAddressError,
      "Unable to determine address of the Marketplace smart contract")
    return failure(err)

  let contract = Marketplace.new(address, signer)
  let market = OnChainMarket.new(contract)
  let clock = OnChainClock.new(signer.provider)

  return success((contract, market, clock))

proc prepare*(
  providerUrl: string = "ws://localhost:8545",
  account: Address,
  deploymentFile: ?string):
  ?!tuple[signer: JsonRpcSigner, deploy: Deployment] =

  let provider = JsonRpcProvider.new(providerUrl)
  let signer = provider.getSigner(account)

  var deploy: Deployment
  try:
    deploy = deployment(deploymentFile)
  except IOError as e:
    let err = newException(ReadDeploymentFileFailureError,
      "Unable to read deployment json")
    err.parent = e
    return failure(err)

  return success((signer, deploy))

method start*(self: ContractInteractions) {.async, base.} =
  await self.clock.start()

method stop*(self: ContractInteractions) {.async, base.} =
  await self.clock.stop()
