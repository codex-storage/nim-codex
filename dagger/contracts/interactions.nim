import pkg/ethers
import ../purchasing
import ../sales
import ../proving
import ./deployment
import ./storage
import ./market
import ./proofs

export purchasing
export sales
export proving

type
  ContractInteractions* = ref object
    purchasing*: Purchasing
    sales*: Sales
    proving*: Proving

proc new*(_: type ContractInteractions,
          signer: Signer,
          deployment: Deployment): ContractInteractions =
  let contract = Storage.new(!deployment.address(Storage), signer)
  let market = OnChainMarket.new(contract)
  let proofs = OnChainProofs.new(contract)
  ContractInteractions(
    purchasing: Purchasing.new(market),
    sales: Sales.new(market),
    proving: Proving.new(proofs)
  )

proc new*(_: type ContractInteractions): ContractInteractions =
  let provider = JsonRpcProvider.new("ws://localhost:8545")
  let signer = provider.getSigner()
  ContractInteractions.new(signer, deployment())
