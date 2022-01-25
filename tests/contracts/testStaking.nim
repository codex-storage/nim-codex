import pkg/chronos
import pkg/stint
import dagger/contracts
import dagger/contracts/testtoken
import ./ethertest

ethersuite "Staking":

  let stakeAmount = 100.u256

  var storage: Storage
  var token: TestToken

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())
    await token.mint(accounts[0], 1000.u256)

  test "increases stake":
    await token.approve(storage.address, stakeAmount)
    await storage.increaseStake(stakeAmount)
    let stake = await storage.stake(accounts[0])
    check stake == stakeAmount

  test "withdraws stake":
    await token.approve(storage.address, stakeAmount)
    await storage.increaseStake(stakeAmount)
    let balanceBefore = await token.balanceOf(accounts[0])
    await storage.withdrawStake()
    let balanceAfter = await token.balanceOf(accounts[0])
    check (balanceAfter - balanceBefore) == stakeAmount
