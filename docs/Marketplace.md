# Running Codex with Marketplace

This tutorial will provide you with information on how to run a small Codex network with the _storage marketplace_ enabled; i.e., the functionality in Codex which allows participants to offer and buy storage in a market, ensuring that storage providers honor their part of the deal by means of cryptographic proofs.

To complete this guide, you will need:

* the [geth](https://github.com/ethereum/go-ethereum) Ethereum client;
* a Codex binary, which [you can compile from source](https://github.com/codex-storage/nim-codex?tab=readme-ov-file#build-and-run).

We will also be using [bash](https://en.wikipedia.org/wiki/Bash_(Unix_shell)) syntax throughout. If you use a different shell, you may need to adapt things to your platform.

This guide has four major steps:

1. [Setting Up a Geth PoA network](#1-setting-up-a-geth-poa-network);
2. [Setting up The Marketplace](#2-setting-up-the-marketplace);
3. [Running Codex](#3-running-codex);
4. [Buying and Selling Storage]()

We suggest you create a folder (e.g. `marketplace-tutorial`) and switch into it before beginning.

## 1. Setting Up a Geth PoA Network

For this tutorial, we will use a simple [Proof-of-Authority](https://github.com/ethereum/EIPs/issues/225) network with geth. The first step is creating a _signer account_: an account which will be used by geth to sign the blocks in the network. Any block signed by a signer is accepted as valid.

### 1.1. Create a Signer Account

To create a signer account, run:

```bash
geth account new --datadir geth-data
```

The account generator will ask you to input a password, which you can leave blank. It will then print some information, including the account's public address:

```bash
INFO [03-22|12:58:05.637] Maximum peer count                       ETH=50 total=50
INFO [03-22|12:58:05.638] Smartcard socket not found, disabling    err="stat /run/pcscd/pcscd.comm: no such file or directory"
Your new account is locked with a password. Please give a password. Do not forget this password.
Password:
Repeat password:

Your new key was generated

Public address of the key:   0x93976895c4939d99837C8e0E1779787718EF8368
...
```

In this example, the public address of the signer account is `0x93976895c4939d99837C8e0E1779787718EF8368`. Yours will print a different address; write it down.

### 1.2. Configure The Network and Create the Genesis Block

The next step is telling geth what kind of network you want to run. We will be running a [pre-merge](https://ethereum.org/en/roadmap/merge/) network with Proof-of-Authority consensus. To get that working, create a `network.json` file with the following content:

```json
{
  "config": {
    "chainId": 12345,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "arrowGlacierBlock": 0,
    "grayGlacierBlock": 0,
    "clique": {
      "period": 1,
      "epoch": 30000
    }
  },
  "difficulty": "1",
  "gasLimit": "8000000",
  "extradata": "0x000000000000000000000000000000000000000000000000000000000000000093976895c4939d99837C8e0E1779787718EF83680000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  "alloc": {
    "0x93976895c4939d99837C8e0E1779787718EF8368": {
      "balance": "10000000000000000000000"
    }
  }
}
```

Note that the signer account address is embedded in two different places:
* inside of the `"extradata"` string, surrounded by zeroes and stripped of its `0x` prefix;
* as an entry key in the `alloc` session.

Make sure to replace that ID with the account ID that you wrote down in Step 1.1. Once that is done, you can initialize the network with:

```bash
geth init --datadir geth-data network.json
```

### 1.3. Start your PoA Node

We are now ready to start our $1$-node, private blockchain. To launch the signer node, open a separate terminal on the same working directory and run:

```bash
geth\
  --datadir geth-data\
  --networkid 12345\
  --unlock <signer-account-address>\
  --password <your-accounts-password>\
  --nat extip:127.0.0.1\
  --netrestrict 127.0.0.0/24\
  --mine\
  --miner.etherbase <signer-account-address>\
  --http\
  --allow-insecure-unlock
```

Note that, once again, the signer account created in Step 1.1 appears both in `--unlock` and `--allow-insecure-unlock`. Do not forget to insert it there.

## 2. Setting Up The Marketplace

Setting up the marketplace entails deploying the Codex Marketplace contracts and providing tokens to the accounts we wish to use later for buying and selling storage.

### 2.1. Deploy the Codex Marketplace Contracts

To deploy the contracts, start by cloning the Codex contracts repository locally and installing its dependencies:

```bash
git clone https://github.com/codex-storage/codex-contracts-eth
cd codex-contracts-eth
npm install
```
You now must **wait until $256$ blocks are mined in your PoA network**, or deploy will fail. This should take about $4$ minutes and $30$ seconds. You can check which block height you are currently at by running:

```bash
geth attach --exec web3.eth.blockNumber ./geth-data/geth.ipc
```

once that gets past $256$, you are ready to go. To deploy contracts, run:

```bash
export DISTTEST_NETWORK_URL=http://localhost:8545 # bootstrap node
npx hardhat --network codexdisttestnetwork deploy
```

If the command completes successfully, you are ready to prepare the accounts.

### 2.2. Generating the Accounts

We will run $2$ Codex nodes: a **storage provider**, which will sell storage on the network, and a **client**, which will buy and use such storage; we therefore need two valid Ethereum accounts. We could create random accounts by using one of the many  tools available to that end but, since this is a tutorial running on a local private network, we will simply provide you with two pre-made accounts along with their private keys which you can copy and paste instead:

**Storage:**
```text
address: 0x45BC5ca0fbdD9F920Edd12B90908448C30F32a37
private key: 0x06c7ac11d4ee1d0ccb53811b71802fa92d40a5a174afad9f2cb44f93498322c3
```
**Client:**
```text
address: 0x9F0C62Fe60b22301751d6cDe1175526b9280b965
private key: 0x5538ec03c956cb9d0bee02a25b600b0225f1347da4071d0fd70c521fdc63c2fc
```

### 2.3. Providing the Accounts with Tokens

We now need to transfer some ETH to each of the accounts, as well as provide them with some Codex tokens for the storage node to use as collateral and for the client node to buy actual storage.

Although the process is not particularly complicated, I suggest you use [the script we prepared](https://github.com/gmega/local-codex-bare/blob/main/scripts/mint-tokens.js) for that. This script, essentially:

1. reads the Marketplace contract address and its ABI from the deployment data;
2. transfers $1$ ETH from the signer account to a target account if the target account has no ETH balance;
3. mints $n$ Codex tokens and adds it into the target account's balance.

To use the script, just copy it locally into a file named `mint-tokens.js`, and run:

```bash
# Installs Web3-js
npm install web3
# Provides tokens to the storage account.
node ./mint-tokens.js <signer account address> 0x45BC5ca0fbdD9F920Edd12B90908448C30F32a37 10000000000
# Provides tokens to the client account.
node ./mint-tokens.js <signer account address> 0x9F0C62Fe60b22301751d6cDe1175526b9280b965 10000000000
```

Don't forget to replace `<signer account address>` with the address of the signer account you created in Step 1.1.

## 3. Running Codex

With accounts and geth in place, we can now start the Codex nodes.

### 3.1. Storage Node

The storage node will be the one storing data and submitting the proofs of storage to the chain. To do that, it needs access to:

1. the address of the Marketplace contract that has been deploy to the local geth node;
2. the sample ceremony files which are shipped in the Codex contracts repo.

Recall you have clone the `codex-contracts-eth` repository in Step 2.1. All of the required files are in there.

**Contract Address.** The contract address can be found inside of the file `codex-contracts-eth/deployments/codexdisttestnetwork/Marketplace.json`:

```bash
> grep '"address":' Marketplace.json
  "address": "0x8891732D890f5A7B7181fBc70F7482DE28a7B60f",
```

**Prover ceremony files.** The ceremony files are under the `codex-contracts-eth/verifier/networks/codexdisttestnetwork` subdirectory. There are three of them: `proof_main.r1cs`, `proof_main.zkey`, and `prooof_main.wasm`. We will need all of them to start the Codex storage node.

**Starting the storage node.** Let:

* `PROVER_ASSETS` contain the directory where the prover ceremony file are located;
* `CODEX_BINARY` contain the location of your Codex binary;
* `MARKETPLACE_ADDRESS` contain the address of the Marketplace contract.

To launch the storage node, run:

```bash
${CODEX_BINARY}\
  --data-dir=./codex-storage\
  --listen-addrs=/ip4/0.0.0.0/tcp/8080\
  --api-port=8000\
  --disc-port=8090\
  persistence\
  --eth-provider=http://localhost:8545\
  --eth-private-key=<(echo -n "0x06c7ac11d4ee1d0ccb53811b71802fa92d40a5a174afad9f2cb44f93498322c3")\
  --marketplace-address=${MARKETPLACE_ADDRESS}\
  --validator\
  --validator-max-slots=1000\
  prover\
  --circom-r1cs=${PROVER_ASSETS}/proof_main.r1cs\
  --circom-wasm=${PROVER_ASSETS}/proof_main.wasm\
  --circom-zkey=${PROVER_ASSETS}/proof_main.zkey
```
replacing each `${VALUE}` variable by their respective contents. We then extract the Signed Peer Record (SPR) of the storage node so we can bootstrap the client node with it. To get the SPR, issue the following call:

```bash
curl 'http://localhost:8080/api/codex/v1/debug/info'
```

This will print a long JSON string:

```json
{"id":"16Uiu2HAm4yoghEaNy1VPLumvXwrFSEenzG1zSy3EcTFYLE2mynjp","addrs":["/ip4/0.0.0.0/tcp/8070"],"repo":"/data","spr":"spr:CiUIAhIhAo30ewLoBnzU5COMicomRT6UAfdmDJbdwQRnba0cvHnnEgIDARo8CicAJQgCEiECjfR7AugGfNTkI4yJyiZFPpQB92YMlt3BBGdtrRy8eecQqrWcsAYaCwoJBLNdyciRAh-aKkYwRAIgFnH5tSmOlxrSnOwyOHjnjBVSrEXZOeosH1i9gzoDI6UCIEnCI82Bb4iATMKKuaZCfVNlEOmwnfAG-6z0RuJJc-8s",...
```
The part we care about is the SPR (the string after `"spr":`). Write that string down.

**Starting the client node.** The client node is started similarly except that:

* we need to pass the SPR of the storage node so it can form a network with it;
* since it does not run any proofs, it does not require any ceremony files.

```bash
${CODEX_BINARY}\
  --data-dir=./codex-client\
  --listen-addrs=/ip4/0.0.0.0/tcp/8081\
  --api-port=8001\
  --disc-port=8091\
  --bootstrap-node=<storage-node-spr>
  persistence\
  --eth-provider=http://localhost:8545\
  --eth-private-key=<(echo -n "0x5538ec03c956cb9d0bee02a25b600b0225f1347da4071d0fd70c521fdc63c2fc")\
  --marketplace-address=${MARKETPLACE_ADDRESS}
```

## 4. Buying and Selling Storage
