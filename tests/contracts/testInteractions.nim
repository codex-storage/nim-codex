import std/os
import pkg/datastore
import pkg/codex/contracts
import pkg/codex/stores
import ../ethertest
import ./examples

ethersuite "Marketplace Contract Interactions - Client":

  let url = "http://localhost:8545"
  let account = Address.example
  let contractAddress = Address.example

  test "can be instantiated with a provider url, account, and contract address":
    check ClientInteractions.new(url, account, contractAddress).isSuccess

  test "provides purchasing":
    let client = !ClientInteractions.new(url, account, contractAddress)
    check client.purchasing != nil

ethersuite "Marketplace Contract Interactions - Host":

  let url = "http://localhost:8545"
  let account = Address.example
  let contractAddress = Address.example

  var
    repo: RepoStore
    repoDs: Datastore
    metaDs: Datastore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)

  test "can be instantiated with a provider url, account, repo, and contract address":
    check HostInteractions.new(url, account, repo, contractAddress).isSuccess

  test "provides sales":
    let host = !HostInteractions.new(url, account, repo, contractAddress)
    check host.sales != nil

  test "provides proving":
    let host = !HostInteractions.new(url, account, repo, contractAddress)
    check host.proving != nil
