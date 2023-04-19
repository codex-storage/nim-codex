import std/os
import pkg/codex/contracts
import pkg/codex/stores
import ../ethertest

suite "Deployment":
  let deploymentFile = "vendor" / "codex-contracts-eth" / "deployment-localhost.json"

  test "can be instantiated with a deployment file":
    discard Deployment.init(deploymentFile)

  test "contract address can be retreived from deployment json":
    let deployment = Deployment.init(deploymentFile)
    check deployment.address(Marketplace).isSome

  test "can be instantiated without a deployment file":
    discard Deployment.init()
