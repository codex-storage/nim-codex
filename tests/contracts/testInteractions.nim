import std/os
import codex/contracts
import ../ethertest
import ./examples

ethersuite "Storage Contract Interactions":

  var contracts: ContractInteractions

  setup:
    contracts = !ContractInteractions.new()

  test "can be instantiated with a signer and deployment info":
    let signer = provider.getSigner()
    let deployment = deployment()
    check ContractInteractions.new(signer, deployment).isSome

  test "can be instantiated with a provider url and account":
    let url = "http://localhost:8545"
    let account = Address.example
    let deployment = "vendor" / "dagger-contracts" / "deployment-localhost.json"
    check ContractInteractions.new(url).isSome
    check ContractInteractions.new(url, account = account).isSome
    check ContractInteractions.new(url, deploymentFile = deployment).isSome

  test "provides purchasing":
    check contracts.purchasing != nil

  test "provides sales":
    check contracts.sales != nil

  test "provides proving":
    check contracts.proving != nil
