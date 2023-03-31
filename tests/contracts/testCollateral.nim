import pkg/chronos
import pkg/stint
import codex/contracts
import codex/contracts/testtoken
import ../ethertest

ethersuite "Collateral":

  let collateral = 100.u256

  var marketplace: Marketplace
  var token: TestToken

  setup:
    let deployment = Deployment.init()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())
    await token.mint(accounts[0], 1000.u256)

  test "increases collateral":
    await token.approve(marketplace.address, collateral)
    await marketplace.deposit(collateral)
    let balance = await marketplace.balanceOf(accounts[0])
    check balance == collateral

  test "withdraws collateral":
    await token.approve(marketplace.address, collateral)
    await marketplace.deposit(collateral)
    let balanceBefore = await token.balanceOf(accounts[0])
    await marketplace.withdraw()
    let balanceAfter = await token.balanceOf(accounts[0])
    check (balanceAfter - balanceBefore) == collateral
