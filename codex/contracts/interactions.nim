import pkg/ethers
import pkg/chronicles
import ../purchasing
import ../sales
import ../proving
import ./deployment
import ./marketplace
import ./market
import ./proofs
import ./clock

export purchasing
export sales
export proving
export chronicles

type
  ContractInteractions* = ref object
    purchasing*: Purchasing
    sales*: Sales
    proving*: Proving
    clock: OnChainClock

proc new*(_: type ContractInteractions,
          signer: Signer,
          deployment: Deployment): ?ContractInteractions =

  without address =? deployment.address(Marketplace):
    error "Unable to determine address of the Marketplace smart contract"
    return none ContractInteractions

  let contract = Marketplace.new(address, signer)
  let market = OnChainMarket.new(contract)
  let proofs = OnChainProofs.new(contract)
  let clock = OnChainClock.new(signer.provider)
  let proving = Proving.new(proofs, clock)
  some ContractInteractions(
    purchasing: Purchasing.new(market, clock),
    sales: Sales.new(market, clock, proving),
    proving: proving,
    clock: clock
  )

proc new*(_: type ContractInteractions,
          providerUrl: string,
          account: Address,
          deploymentFile: string = string.default): ?ContractInteractions =

  let provider = JsonRpcProvider.new(providerUrl)
  let signer = provider.getSigner(account)

  var deploy: Deployment
  try:
    if deploymentFile == string.default:
      deploy = deployment()
    else:
      deploy = deployment(deploymentFile)
  except IOError as e:
    error "Unable to read deployment json", msg = e.msg
    return none ContractInteractions

  ContractInteractions.new(signer, deploy)

proc new*(_: type ContractInteractions,
          account: Address): ?ContractInteractions =
  ContractInteractions.new("ws://localhost:8545", account)

proc start*(interactions: ContractInteractions) {.async.} =
  await interactions.clock.start()
  await interactions.sales.start()
  await interactions.proving.start()
  await interactions.purchasing.start()

proc stop*(interactions: ContractInteractions) {.async.} =
  await interactions.purchasing.stop()
  await interactions.sales.stop()
  await interactions.proving.stop()
  await interactions.clock.stop()
