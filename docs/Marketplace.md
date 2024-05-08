# Running a Local Codex Network with Marketplace Support

This tutorial will teach you how to run a small Codex network with the _storage marketplace_ enabled; i.e., the functionality in Codex which allows participants to offer and buy storage in a market, ensuring that storage providers honor their part of the deal by means of cryptographic proofs.

To complete this tutorial, you will need:

* the [geth](https://github.com/ethereum/go-ethereum) Ethereum client;
* a Codex binary, which [you can compile from source](https://github.com/codex-storage/nim-codex?tab=readme-ov-file#build-and-run).

We will also be using [bash](https://en.wikipedia.org/wiki/Bash_(Unix_shell)) syntax throughout. If you use a different shell, you may need to adapt things to your platform.

In this tutorial, you will:

1. [Set Up a Geth PoA network](#1-set-up-a-geth-poa-network);
2. [Set up The Marketplace](#2-set-up-the-marketplace);
3. [Run Codex](#3-run-codex);
4. [Buy and Sell Storage in the Marketplace](#4-buy-and-sell-storage-on-the-marketplace).

We strongly suggest you to create a folder (e.g. `marketplace-tutorial`), and switch into it before beginning.

## 1. Set Up a Geth PoA Network

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

In this example, the public address of the signer account is `0x93976895c4939d99837C8e0E1779787718EF8368`. Yours will print a different address. Save it for later usage.

Next set an environment variable for later usage:

```sh
export GETH_SIGNER_ADDR="0x0000000000000000000000000000000000000000"
echo ${GETH_SIGNER_ADDR} > geth_signer_address.txt
```

### 1.2. Configure The Network and Create the Genesis Block

The next step is telling geth what kind of network you want to run. We will be running a [pre-merge](https://ethereum.org/en/roadmap/merge/) network with Proof-of-Authority consensus. To get that working, create a `network.json` file.

If you set the GETH_SIGNER_ADDR variable above you can run to create the `network.json` file:

```sh
echo  "{\"config\": { \"chainId\": 12345, \"homesteadBlock\": 0, \"eip150Block\": 0, \"eip155Block\": 0, \"eip158Block\": 0, \"byzantiumBlock\": 0, \"constantinopleBlock\": 0, \"petersburgBlock\": 0, \"istanbulBlock\": 0, \"berlinBlock\": 0, \"londonBlock\": 0, \"arrowGlacierBlock\": 0, \"grayGlacierBlock\": 0, \"clique\": { \"period\": 1, \"epoch\": 30000 } }, \"difficulty\": \"1\", \"gasLimit\": \"8000000\", \"extradata\": \"0x0000000000000000000000000000000000000000000000000000000000000000${GETH_SIGNER_ADDR:2}0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\", \"alloc\": { \"${GETH_SIGNER_ADDR}\": { \"balance\": \"10000000000000000000000\"}}}" > network.json
```

You can also manually create the file with the following content modified with your signer private key:

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
Make sure to replace that ID with the account ID that you wrote down in Step 1.1.


Once `network.json` is created, you can initialize the network with:

```bash
geth init --datadir geth-data network.json
```

### 1.3. Start your PoA Node

We are now ready to start our $1$-node, private blockchain. To launch the signer node, open a separate terminal on the same working directory and run:

```bash
geth\
  --datadir geth-data\
  --networkid 12345\
  --unlock ${GETH_SIGNER_ADDR}\
  --nat extip:127.0.0.1\
  --netrestrict 127.0.0.0/24\
  --mine\
  --miner.etherbase ${GETH_SIGNER_ADDR}\
  --http\
  --allow-insecure-unlock
```

Note that, once again, the signer account created in Step 1.1 appears both in `--unlock` and `--allow-insecure-unlock`. Make sure you have the `GETH_SIGNER_ADDR` set.

Geth will prompt you to insert the account's password as it starts up. Once you do that, it should be able to start up and begin "mining" blocks.

## 2. Set Up The Marketplace

You will need to open new terminal for this section and geth needs to be running already. Setting up the Codex marketplace entails:

1. Deploying the Codex Marketplace contracts to our private blockchain
2. Setup Ethereum accounts we will use to buy and sell storage in the Codex marketplace
3. Provisioning those accounts with the required token balances

### 2.1. Deploy the Codex Marketplace Contracts

To deploy the contracts, start by cloning the Codex contracts repository locally and installing its dependencies:

```bash
git clone https://github.com/codex-storage/codex-contracts-eth
cd codex-contracts-eth
npm install
```
You now must **wait until $256$ blocks are mined in your PoA network**, or deploy will fail. This should take about $4$ minutes and $30$ seconds. You can check which block height you are currently at by running:

```bash
geth attach --exec web3.eth.blockNumber ../geth-data/geth.ipc
```

once that gets past $256$, you are ready to go. To deploy contracts, run:

```bash
export DISTTEST_NETWORK_URL=http://localhost:8545 # bootstrap node
npx hardhat --network codexdisttestnetwork deploy && cd ../
```

If the command completes successfully, you are ready to prepare the accounts.

### 2.2. Generate the Required Accounts

We will run $2$ Codex nodes: a **storage provider**, which will sell storage on the network, and a **client**, which will buy and use such storage; we therefore need two valid Ethereum accounts. We could create random accounts by using one of the many  tools available to that end but, since this is a tutorial running on a local private network, we will simply provide you with two pre-made accounts along with their private keys which you can copy and paste instead:

First make sure you're back in the `marketplace-tutorial` folder and not the `codex-contracts-eth` subfolder. Then set these variables:

**Storage:**
```sh
export ETH_STORAGE_ADDR=0x45BC5ca0fbdD9F920Edd12B90908448C30F32a37
export ETH_STORAGE_PK=0x06c7ac11d4ee1d0ccb53811b71802fa92d40a5a174afad9f2cb44f93498322c3
echo $ETH_STORAGE_PK > storage.pkey && chmod 0600 storage.pkey
```

**Client:**
```sh
export ETH_CLIENT_ADDR=0x9F0C62Fe60b22301751d6cDe1175526b9280b965
export ETH_CLIENT_PK=0x5538ec03c956cb9d0bee02a25b600b0225f1347da4071d0fd70c521fdc63c2fc
echo $ETH_CLIENT_PK > client.pkey && chmod 0600 client.pkey
```

### 2.3. Provision Accounts with Tokens

We now need to transfer some ETH to each of the accounts, as well as provide them with some Codex tokens for the storage node to use as collateral and for the client node to buy actual storage.

Although the process is not particularly complicated, I suggest you use [the script we prepared](https://github.com/gmega/local-codex-bare/blob/main/scripts/mint-tokens.js) for that. This script, essentially:

1. reads the Marketplace contract address and its ABI from the deployment data;
2. transfers $1$ ETH from the signer account to a target account if the target account has no ETH balance;
3. mints $n$ Codex tokens and adds it into the target account's balance.

To use the script, just download it into a local file named `mint-tokens.js`, for instance using curl:

```bash
# set the contract file location
export CONTRACT_DEPLOY_FULL="codex-contracts-eth/deployments/codexdisttestnetwork"
export GETH_SIGNER_ADDR=$(cat geth_signer_address.txt)
# download script
curl https://raw.githubusercontent.com/gmega/codex-local-bare/main/scripts/mint-tokens.js -o mint-tokens.js
```

```bash
# Installs Web3-js
npm install web3
# Provides tokens to the storage account.
node ./mint-tokens.js $CONTRACT_DEPLOY_FULL/TestToken.json $GETH_SIGNER_ADDR 0x45BC5ca0fbdD9F920Edd12B90908448C30F32a37 10000000000
# Provides tokens to the client account.
node ./mint-tokens.js $CONTRACT_DEPLOY_FULL/TestToken.json $GETH_SIGNER_ADDR 0x9F0C62Fe60b22301751d6cDe1175526b9280b965 10000000000
```

If you get a message like `Usage: mint-tokens.js <token-hardhat-deploy-json> <signer-account> <receiver-account> <token-ammount>` then you need to ensure you have

## 3. Run Codex

With accounts and geth in place, we can now start the Codex nodes.

### 3.1. Storage Node

The storage node will be the one storing data and submitting the proofs of storage to the chain. To do that, it needs access to:

1. the address of the Marketplace contract that has been deployed to the local geth node in [Step 2.1](#21-deploy-the-codex-marketplace-contracts);
2. the sample ceremony files which are shipped in the Codex contracts repo.

Recall you have clone the `codex-contracts-eth` repository in Step 2.1. All of the required files are in there.

**Address of the Marketplace Contract.** The contract address can be found inside of the file `codex-contracts-eth/deployments/codexdisttestnetwork/Marketplace.json`:

```bash
grep '"address":' ${CONTRACT_DEPLOY_FULL}/Marketplace.json
```

which should print something like:
```sh
  "address": "0x8891732D890f5A7B7181fBc70F7482DE28a7B60f",
```

Then run the following with the correct market place address:
```sh
export MARKETPLACE_ADDRESS="0x0000000000000000000000000000000000000000"
echo ${MARKETPLACE_ADDRESS} > marketplace_address.txt
```

**Prover ceremony files.** The ceremony files are under the `codex-contracts-eth/verifier/networks/codexdisttestnetwork` subdirectory. There are three of them: `proof_main.r1cs`, `proof_main.zkey`, and `prooof_main.wasm`. We will need all of them to start the Codex storage node.

**Starting the storage node.** Let:

* `PROVER_ASSETS` contain the directory where the prover ceremony files are located. **This must be an absolute path**;
* `CODEX_BINARY` contain the location of your Codex binary;
* `MARKETPLACE_ADDRESS` contain the address of the Marketplace contract (obtained above).

Set these paths into environment variables (modify it with the correct paths if you changed them above):

```sh
export CONTRACT_DEPLOY_FULL=$(realpath "codex-contracts-eth/deployments/codexdisttestnetwork")
export PROVER_ASSETS=$(realpath "codex-contracts-eth/verifier/networks/codexdisttestnetwork/")
export CODEX_BINARY=$(realpath "../build/codex")
export MARKETPLACE_ADDRESS=$(cat marketplace_address.txt)
```

To launch the storage node, run:

```bash
${CODEX_BINARY}\
  --data-dir=./codex-storage\
  --listen-addrs=/ip4/0.0.0.0/tcp/8080\
  --api-port=8000\
  --disc-port=8090\
  persistence\
  --eth-provider=http://localhost:8545\
  --eth-private-key=./storage.pkey\
  --marketplace-address=${MARKETPLACE_ADDRESS}\
  --validator\
  --validator-max-slots=1000\
  prover\
  --circom-r1cs=${PROVER_ASSETS}/proof_main.r1cs\
  --circom-wasm=${PROVER_ASSETS}/proof_main.wasm\
  --circom-zkey=${PROVER_ASSETS}/proof_main.zkey
```

**Starting the client node.**

The client node is started similarly except that:

* we need to pass the SPR of the storage node so it can form a network with it;
* since it does not run any proofs, it does not require any ceremony files.

We get the Signed Peer Record (SPR) of the storage node so we can bootstrap the client node with it. To get the SPR, issue the following call:

```bash
curl -H 'Accept: text/plain' 'http://localhost:8000/api/codex/v1/spr'
```

You should get the SPR back starting with `spr:`. Next set these paths into environment variables:

```bash
# set the SPR for the storage node
export STORAGE_NODE_SPR=$(curl -H 'Accept: text/plain' 'http://localhost:8000/api/codex/v1/spr')
# basic vars
export CONTRACT_DEPLOY_FULL=$(realpath "codex-contracts-eth/deployments/codexdisttestnetwork")
export PROVER_ASSETS=$(realpath "codex-contracts-eth/verifier/networks/codexdisttestnetwork/")
export CODEX_BINARY=$(realpath "../build/codex")
export MARKETPLACE_ADDRESS=$(cat marketplace_address.txt)
```

```bash
${CODEX_BINARY}\
  --data-dir=./codex-client\
  --listen-addrs=/ip4/0.0.0.0/tcp/8081\
  --api-port=8001\
  --disc-port=8091\
  --bootstrap-node=${STORAGE_NODE_SPR}\
  persistence\
  --eth-provider=http://localhost:8545\
  --eth-private-key=./client.pkey\
  --marketplace-address=${MARKETPLACE_ADDRESS}
```

## 4. Buy and Sell Storage on the Marketplace

Any storage negotiation has two sides: a buyer and a seller. Before we can actually request storage, therefore, we must first put some of it for sale.

### 4.1 Sell Storage

The following request will cause the storage node to put out $50\text{MB}$ of storage for sale for $1$ hour, at a price of $1$ Codex token per byte per second, while expressing that it's willing to take at most a $1000$ Codex token penalty for not fulfilling its part of the contract.[^1]

```bash
curl 'http://localhost:8000/api/codex/v1/sales/availability' \
  --header 'Content-Type: application/json' \
  --data '{
  "totalSize": "50000000",
  "duration": "3600",
  "minPrice": "1",
  "maxCollateral": "1000"
}'
```

This should return a response with an id a string (e.g. `"id": "0x552ef12a2ee64ca22b237335c7e1df884df36d22bfd6506b356936bc718565d4"`) which identifies this storage offer. To check the current storage offers for this node, you can issue:

```bash
curl 'http://localhost:8000/api/codex/v1/sales/availability'
```

This should print a list of offers, with the one you just created figuring among them.

## 4.2. Buy Storage

Before we can buy storage, we must have some actual data to request storage for. Start by uploading a small file to your client node. On Linux you could, for instance, use `dd` to generate a $100KB$ file:

```bash
dd if=/dev/urandom of=./data.bin bs=100K count=1
```

but any small file will do. Assuming your file is named `data.bin`, you can upload it with:

```bash
curl "http://localhost:8001/api/codex/v1/data" --data-bin @data.bin
```

Once the upload completes, you should see a CID (e.g. `zDvZRwzm2mK7tvDzKScRLapqGdgNTLyyEBvx1TQY37J2CdWdS6Sj`) for the file printed to the terminal. Use that CID in the purchase request:

```bash
export CID=zDvZRwzm2mK7tvDzKScRLapqGdgNTLyyEBvx1TQY37J2CdWdS6Sj
export EXPIRY_TIME=$((1000 + $(date +%s))) # current time + 1000 seconds
                                           # adjust expiry_time as desired, see below
```

```bash
curl "http://localhost:8001/api/codex/v1/storage/request/${CID}" \
  --header 'Content-Type: application/json' \
  --data "{
    \"duration\": \"1200\",
    \"reward\": \"1\",
    \"proofProbability\": \"3\",
    \"expiry\": \"${EXPIRY_TIME}\",
    \"nodes\": 1,
    \"tolerance\": 0,
    \"collateral\": \"1000\"
  }"
```

The parameters under `--data` say that:

1. we want to purchase storage for our file for $20$ minutes (`"duration": "1200"`);
2. we are willing to pay up to $1$ token per byte, per second (`"reward": "1"`);
3. our file will be split into four pieces (`"nodes": 3` and `"tolerance": 1`), so that we only need three pieces to rebuild the file; i.e., we can tolerate that at most one node stops storing our data; either due to failure or other reasons;
4. we demand `1000` tokens in collateral from storage providers for each piece. Since there are $4$ such pieces, there will be `4000` in total collateral committed by all of the storage providers taken together once our request is fulfilled.

Finally, the `expiry` puts a cap on the block time at which our request expires. This has to be at most `current block time + duration`, which means this request can fail if you input the wrong number, which you likely will if you do not know what the current block time is. Fear not, however, as you can try an an arbitrary number (e.g. `1000`), and look at the failure message:

   `Expiry needs to be in future. Now: 1711995463`

to compute a valid one. Just take the number in the error message and add the duration; i.e., `1711995463 + 1200 = 1711996663`, then use the resulting number (`1711996663`) as expiry and things should work. The request should return a purchase ID (e.g. `1d0ec5261e3364f8b9d1cf70324d70af21a9b5dccba380b24eb68b4762249185`), which you can use track the completion of your request in the marketplace.

## 4.3. Track your Storage Requests

POSTing a storage request will make it available in the storage market, and a storage node will eventually pick it up.

You can poll the status of your request by means of:
```bash
export STORAGE_PURCHASE_ID="1d0ec5261e3364f8b9d1cf70324d70af21a9b5dccba380b24eb68b4762249185"
curl "http://localhost:8001/api/codex/v1/storage/purchases/${STORAGE_PURCHASE_ID}"
```

For instance:

```bash
> curl 'http://localhost:8001/api/codex/v1/storage/purchases/6c698cd0ad71c41982f83097d6fa75beb582924e08a658357a1cd4d7a2a6766d'
```

This returns a result like:

```json
{
	"requestId": "0x6c698cd0ad71c41982f83097d6fa75beb582924e08a658357a1cd4d7a2a6766d",
	"request": {
		"client": "0xed6c3c20358f0217919a30c98d72e29ceffedc33",
		"ask": {
			"slots": 3,
			"slotSize": "262144",
			"duration": "1000",
			"proofProbability": "3",
			"reward": "1",
			"collateral": "1",
			"maxSlotLoss": 1
		},
		"content": {
			"cid": "zDvZRwzm3nnkekFLCACmWyKdkYixsX3j9gJhkvFtfYA5K9bpXQnC"
		},
		"expiry": "1711992852",
		"nonce": "0x9f5e651ecd3bf73c914f8ed0b1088869c64095c0d7bd50a38fc92ebf66ff5915",
		"id": "0x6c698cd0ad71c41982f83097d6fa75beb582924e08a658357a1cd4d7a2a6766d"
	},
	"state": "submitted",
  "error": null
}
```

Shows that a request has been submitted but has not yet been filled. Your request will be successful once `"state"` shows `"started"`. Anything other than that means the request has not been completely processed yet, and an `"error"` state other than `null` means it failed.

[^1]: Codex files get partitioned into pieces called "slots" and distributed to various storage providers. The collateral refers to one such slot, and will be slowly eaten away as the storage provider fails to deliver timely proofs, but the actual logic is [more involved than that](https://github.com/codex-storage/codex-contracts-eth/blob/6c9f797f408608958714024b9055fcc330e3842f/contracts/Marketplace.sol#L209).
