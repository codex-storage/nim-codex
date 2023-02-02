import std/os

import pkg/datastore

import pkg/codex/contracts
import pkg/codex/stores

import ../ethertest
import ./examples

ethersuite "Marketplace Contract Client Interactions":

  let account = Address.example

  var contracts: ClientInteractions

  setup:
    contracts = !ClientInteractions.new(account)

  test "can be instantiated with a signer and deployment info":
    let signer = provider.getSigner()
    let deployment = deployment()
    check ClientInteractions.new(signer, deployment).isSome

  test "can be instantiated with a provider url":
    let url = "http://localhost:8545"
    let account = Address.example
    let deployment = "vendor" / "codex-contracts-eth" / "deployment-localhost.json"
    check ClientInteractions.new(url, account).isSome
    check ClientInteractions.new(url, account, deployment).isSome

  test "provides purchasing":
    check contracts.purchasing != nil

ethersuite "Marketplace Contract Host Interactions":

  let account = Address.example

  var
    contracts: HostInteractions
    repo: RepoStore

  setup:
    let repoDs = SQLiteDatastore.new(Memory).tryGet()
    let metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)
    contracts = !HostInteractions.new(account, repo)

  test "can be instantiated with a signer and deployment info":
    let signer = provider.getSigner()
    let deployment = deployment()
    check HostInteractions.new(signer, deployment, repo).isSome

  test "can be instantiated with a provider url":
    let url = "http://localhost:8545"
    let account = Address.example
    let deployment = "vendor" / "codex-contracts-eth" / "deployment-localhost.json"
    check HostInteractions.new(url, account, repo).isSome
    check HostInteractions.new(url, account, repo, deployment).isSome

  test "provides sales":
    check contracts.sales != nil

  test "provides proving":
    check contracts.proving != nil
