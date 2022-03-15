import pkg/chronos
import pkg/stint
import dagger/contracts
import dagger/contracts/testtoken
import ./ethertest

ethersuite "Collateral":

  let collateralAmount = 100.u256

  var storage: Storage
  var token: TestToken

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())
    await token.mint(accounts[0], 1000.u256)

  test "increases collateral":
    await token.approve(storage.address, collateralAmount)
    await storage.deposit(collateralAmount)
    let collateral = await storage.balanceOf(accounts[0])
    check collateral == collateralAmount

  test "withdraws collateral":
    await token.approve(storage.address, collateralAmount)
    await storage.deposit(collateralAmount)
    let balanceBefore = await token.balanceOf(accounts[0])
    await storage.withdraw()
    let balanceAfter = await token.balanceOf(accounts[0])
    check (balanceAfter - balanceBefore) == collateralAmount
