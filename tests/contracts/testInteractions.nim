import ./ethertest
import dagger/contracts
import ./examples

ethersuite "Storage Contract Interactions":

  var contracts: ContractInteractions

  setup:
    contracts = ContractInteractions.new()

  test "can be instantiated with a signer and deployment info":
    let signer = provider.getSigner()
    let deployment = deployment()
    check ContractInteractions.new(signer, deployment) != nil

  test "can be instantiated with a provider url and account":
    let url = "http://localhost:8545"
    let account = Address.example
    check ContractInteractions.new(url) != nil
    check ContractInteractions.new(url, account) != nil

  test "provides purchasing":
    check contracts.purchasing != nil

  test "provides sales":
    check contracts.sales != nil

  test "provides proving":
    check contracts.proving != nil
