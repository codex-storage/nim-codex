import std/os
import pkg/datastore
import pkg/codex/contracts
import pkg/codex/stores
import ../ethertest
import ./examples

# suite "Marketplace Contract Interactions":

ethersuite "Marketplace Contract Interactions - Client":

  let account = Address.example

  var contracts: ClientInteractions

  setup:
    contracts = !ClientInteractions.new(account)

  test "can be instantiated with a signer and deployment info":
    let signer = provider.getSigner()
    let deployment = deployment()
    check ClientInteractions.new(signer, deployment).isSuccess

  test "can be instantiated with a provider url":
    let url = "http://localhost:8545"
    let account = Address.example
    let deployment = some "vendor" / "codex-contracts-eth" / "deployment-localhost.json"
    check ClientInteractions.new(url, account).isSuccess
    check ClientInteractions.new(url, account, deployment).isSuccess

  test "provides purchasing":
    check contracts.purchasing != nil

ethersuite "Marketplace Contract Interactions - Host":

  let account = Address.example

  var
    contracts: HostInteractions
    repo: RepoStore
    repoDs: Datastore
    metaDs: Datastore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)
    contracts = !HostInteractions.new(account, repo)

  test "can be instantiated with a signer and deployment info":
    let signer = provider.getSigner()
    let deployment = deployment()
    check HostInteractions.new(signer, deployment, repo).isSuccess

  test "can be instantiated with a provider url":
    let url = "http://localhost:8545"
    let account = Address.example
    let deployment = some "vendor" / "codex-contracts-eth" / "deployment-localhost.json"
    check HostInteractions.new(url, account, repo).isSuccess
    check HostInteractions.new(url, account, repo, deployment).isSuccess

  test "provides sales":
    check contracts.sales != nil

  test "provides proving":
    check contracts.proving != nil
