import ./ethertest
import dagger/contracts

ethersuite "Storage Contract Interactions":

  var contracts: ContractInteractions

  setup:
    contracts = ContractInteractions.new()

  test "can be instantiated with a signer and deployment info":
    let signer = provider.getSigner()
    let deployment = deployment()
    check ContractInteractions.new(signer, deployment) != nil

  test "provides purchasing":
    check contracts.purchasing != nil

  test "provides sales":
    check contracts.sales != nil

  test "provides proving":
    check contracts.proving != nil
