# Running a Local Codex Network with Marketplace Support

This tutorial will teach you how to run a small Codex network with the
_storage marketplace_ enabled; i.e., the functionality in Codex which
allows participants to offer and buy storage in a market, ensuring that
storage providers honor their part of the deal by means of cryptographic proofs.

## Prerequisites

To complete this tutorial, you will need:

* the [geth](https://github.com/ethereum/go-ethereum) Ethereum client;
  You need version `1.13.x` of geth as newer versions no longer support
  Proof of Authority (PoA). This tutorial was tested using geth version `1.13.15`.
* a Codex binary, which [you can compile from source](https://github.com/codex-storage/nim-codex?tab=readme-ov-file#build-and-run).

We will also be using [bash](https://en.wikipedia.org/wiki/Bash_(Unix_shell))
syntax throughout. If you use a different shell, you may need to adapt
things to your platform.

In this tutorial, you will:

1. [Set Up a Geth PoA network](#1-set-up-a-geth-poa-network);
2. [Set up The Marketplace](#2-set-up-the-marketplace);
3. [Run Codex](#3-run-codex);
4. [Buy and Sell Storage in the Marketplace](#4-buy-and-sell-storage-on-the-marketplace).

To get started, create a new folder where we will keep the tutorial-related
files so that we can keep them separate from the codex repository.
We assume the name of the folder to be `marketplace-tutorial`.

## 1. Set Up a Geth PoA Network

For this tutorial, we will use a simple
[Proof-of-Authority](https://github.com/ethereum/EIPs/issues/225) network
with geth. The first step is creating a _signer account_: an account which
will be used by geth to sign the blocks in the network.
Any block signed by a signer is accepted as valid.

### 1.1. Create a Signer Account

To create a signer account, from the `marketplace-tutorial` directory run:

```bash
geth account new --datadir geth-data
```

The account generator will ask you to input a password, which you can
leave blank. It will then print some information,
including the account's public address:

```bash
INFO [09-29|16:49:24.244] Maximum peer count                       ETH=50 total=50
Your new account is locked with a password. Please give a password. Do not forget this password.
Password:
Repeat password:

Your new key was generated

Public address of the key:   0x33A904Ad57D0E2CB8ffe347D3C0E83C2e875E7dB
Path of the secret key file: geth-data/keystore/UTC--2024-09-29T14-49-31.655272000Z--33a904ad57d0e2cb8ffe347d3c0e83c2e875e7db

- You can share your public address with anyone. Others need it to interact with you.
- You must NEVER share the secret key with anyone! The key controls access to your funds!
- You must BACKUP your key file! Without the key, it's impossible to access account funds!
- You must REMEMBER your password! Without the password, it's impossible to decrypt the key!
```

In this example, the public address of the signer account is
`0x33A904Ad57D0E2CB8ffe347D3C0E83C2e875E7dB`.
Yours will print a different address. Save it for later usage.

Next set an environment variable for later usage:

```bash
export GETH_SIGNER_ADDR="0x0000000000000000000000000000000000000000"
echo ${GETH_SIGNER_ADDR} > geth_signer_address.txt
```

> Here make sure you replace `0x0000000000000000000000000000000000000000`
> with your public address of the signer account
> (`0x93976895c4939d99837C8e0E1779787718EF8368` in our example).

### 1.2. Configure The Network and Create the Genesis Block

The next step is telling geth what kind of network you want to run.
We will be running a [pre-merge](https://ethereum.org/en/roadmap/merge/)
network with Proof-of-Authority consensus.
To get that working, create a `network.json` file.

If you set the GETH_SIGNER_ADDR variable above you can run the following
command to create the `network.json` file:

```bash
echo  "{\"config\": { \"chainId\": 12345, \"homesteadBlock\": 0, \"eip150Block\": 0, \"eip155Block\": 0, \"eip158Block\": 0, \"byzantiumBlock\": 0, \"constantinopleBlock\": 0, \"petersburgBlock\": 0, \"istanbulBlock\": 0, \"berlinBlock\": 0, \"londonBlock\": 0, \"arrowGlacierBlock\": 0, \"grayGlacierBlock\": 0, \"clique\": { \"period\": 1, \"epoch\": 30000 } }, \"difficulty\": \"1\", \"gasLimit\": \"8000000\", \"extradata\": \"0x0000000000000000000000000000000000000000000000000000000000000000${GETH_SIGNER_ADDR:2}0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\", \"alloc\": { \"${GETH_SIGNER_ADDR}\": { \"balance\": \"10000000000000000000000\"}}}" > network.json
```

You can also manually create the file remembering update it with your
signer public address:

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
  "extradata": "0x000000000000000000000000000000000000000000000000000000000000000033A904Ad57D0E2CB8ffe347D3C0E83C2e875E7dB0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  "alloc": {
    "0x33A904Ad57D0E2CB8ffe347D3C0E83C2e875E7dB": {
      "balance": "10000000000000000000000"
    }
  }
}
```

Note that the signer account address is embedded in two different places:
* inside of the `"extradata"` string, surrounded by zeroes and stripped of
  its `0x` prefix;
* as an entry key in the `alloc` session.
  Make sure to replace that ID with the account ID that you wrote down in
  [Step 1.1](#11-create-a-signer-account).

Once `network.json` is created, you can initialize the network with:

```bash
geth init --datadir geth-data network.json
```

The output of the above command you may include some warnings, like:

```bash
WARN [08-21|14:48:12.305] Unknown config environment variable      envvar=GETH_SIGNER_ADDR
```

or even errors when running the command for the first time:

```bash
ERROR[08-21|14:48:12.399] Head block is not reachable
```

The important part is that at the end you should see something similar to:

```bash
INFO [08-21|14:48:12.639] Successfully wrote genesis state         database=lightchaindata hash=768bf1..42d06a
```

### 1.3. Start your PoA Node

We are now ready to start our $1$-node, private blockchain.
To launch the signer node, open a separate terminal in the same working
directory and make sure you have the `GETH_SIGNER_ADDR` set.
For convenience use the `geth_signer_address.txt`:

```bash
export GETH_SIGNER_ADDR=$(cat geth_signer_address.txt)
```

Having the `GETH_SIGNER_ADDR` variable set, run:

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

Note that, once again, the signer account created in
[Step 1.1](#11-create-a-signer-account) appears both in
`--unlock` and `--allow-insecure-unlock`.

Geth will prompt you to insert the account's password as it starts up.
Once you do that, it should be able to start up and begin "mining" blocks.

Also here, you may encounter errors like:

```bash
ERROR[08-21|15:00:27.625] Bootstrap node filtered by netrestrict   id=c845e51a5e470e44 ip=18.138.108.67
ERROR[08-21|15:00:27.625] Bootstrap node filtered by netrestrict   id=f23ac6da7c02f84a ip=3.209.45.79
ERROR[08-21|15:00:27.625] Bootstrap node filtered by netrestrict   id=ef2d7ab886910dc8 ip=65.108.70.101
ERROR[08-21|15:00:27.625] Bootstrap node filtered by netrestrict   id=6b36f791352f15eb ip=157.90.35.166
```

You can safely ignore them.

If the command above fails with:

```bash
Fatal: Failed to register the Ethereum service: only PoS networks are supported, please transition old ones with Geth v1.13.x
```

make sure, you are running the correct Geth version
(see Section [Prerequisites](#prerequisites))

## 2. Set Up The Marketplace

You will need to open new terminal for this section and geth needs to be
running already. Setting up the Codex marketplace entails:

1. Deploying the Codex Marketplace contracts to our private blockchain
2. Setup Ethereum accounts we will use to buy and sell storage in
   the Codex marketplace
3. Provisioning those accounts with the required token balances

### 2.1. Deploy the Codex Marketplace Contracts

Make sure you leave the `marketplace-tutorial` directory, and clone
the `codex-storage/nim-codex.git`:

```bash
git clone https://github.com/codex-storage/nim-codex.git
```

> If you just want to clone the repo to run the tutorial, you can
> skip the history and just download the head of the master branch by using
> `--depth 1` option: `git clone --depth 1 https://github.com/codex-storage/nim-codex.git`

Thus, our directory structure for the purpose of this tutorial looks like this:

```bash
|
|-- nim-codex
└-- marketplace-tutorial
```

> You could clone the `codex-storage/nim-codex.git` to some other location.
> Just to keeps things nicely separated it is best to make sure that
> `nim-codex` is not under `marketplace-tutorial` directory.

Now, from the `nim-codex` folder run:

```bash
make update && make
```

> This may take a moment as it will also build the `nim` compiler. Be patient.

Now, in order to start a local Ethereum network run:

```bash
cd vendor/codex-contracts-eth
npm install
```

> While writing the document we used `node` version `v20.17.0` and
> `npm` version `10.8.2`.

Before continuing you now must **wait until $256$ blocks are mined**
**in your PoAnetwork**, or deploy will fail. This should take about
$4$ minutes and $30$ seconds. You can check which block height you are
currently at by running the following command
**from the `marketplace-tutorial` folder**:

```bash
geth attach --exec web3.eth.blockNumber ./geth-data/geth.ipc
```

once that gets past $256$, you are ready to go.

To deploy contracts, from the `codex-contracts-eth` directory run:

```bash
export DISTTEST_NETWORK_URL=http://localhost:8545
npx hardhat --network codexdisttestnetwork deploy
```

If the command completes successfully, you will see the output similar
to this one:

```bash
Deployed Marketplace with Groth16 Verifier at:
0xCf0df6C52B02201F78E8490B6D6fFf5A82fC7BCd
```
> of course your address will be different.

You are now ready to prepare the accounts.

### 2.2. Generate the Required Accounts

We will run $2$ Codex nodes: a **storage provider**, which will sell storage
on the network, and a **client**, which will buy and use such storage;
we therefore need two valid Ethereum accounts. We could create random
accounts by using one of the many  tools available to that end but, since
this is a tutorial running on a local private network, we will simply
provide you with two pre-made accounts along with their private keys,
which you can copy and paste instead:

First make sure you're back in the `marketplace-tutorial` folder and
not the `codex-contracts-eth` subfolder. Then set these variables:

**Storage:**
```bash
export ETH_STORAGE_ADDR=0x45BC5ca0fbdD9F920Edd12B90908448C30F32a37
export ETH_STORAGE_PK=0x06c7ac11d4ee1d0ccb53811b71802fa92d40a5a174afad9f2cb44f93498322c3
echo $ETH_STORAGE_PK > storage.pkey && chmod 0600 storage.pkey
```

**Client:**
```bash
export ETH_CLIENT_ADDR=0x9F0C62Fe60b22301751d6cDe1175526b9280b965
export ETH_CLIENT_PK=0x5538ec03c956cb9d0bee02a25b600b0225f1347da4071d0fd70c521fdc63c2fc
echo $ETH_CLIENT_PK > client.pkey && chmod 0600 client.pkey
```

### 2.3. Provision Accounts with Tokens

We now need to transfer some ETH to each of the accounts, as well as provide
them with some Codex tokens for the storage node to use as collateral and
for the client node to buy actual storage.

Although the process is not particularly complicated, I suggest you use
[the script we prepared](https://github.com/gmega/local-codex-bare/blob/main/scripts/mint-tokens.js)
for that. This script, essentially:

1. reads the Marketplace contract address and its ABI from the deployment data;
2. transfers $1$ ETH from the signer account to a target account if the target
   account has no ETH balance;
3. mints $n$ Codex tokens and adds it into the target account's balance.

To use the script, just download it into a local file named `mint-tokens.js`,
for instance using `curl` (make sure you are in
the `marketplace-tutorial` directory):

```bash
# download script
curl https://raw.githubusercontent.com/gmega/codex-local-bare/main/scripts/mint-tokens.js -o mint-tokens.js
```

Then run:

```bash
# set the contract file location (we assume you are in the marketplace-tutorial directory)
export CONTRACT_DEPLOY_FULL="../nim-codex/vendor/codex-contracts-eth/deployments/codexdisttestnetwork"
export GETH_SIGNER_ADDR=$(cat geth_signer_address.txt)
# Installs Web3-js
npm install web3
# Provides tokens to the storage account.
node ./mint-tokens.js $CONTRACT_DEPLOY_FULL/TestToken.json $GETH_SIGNER_ADDR 0x45BC5ca0fbdD9F920Edd12B90908448C30F32a37 10000000000
# Provides tokens to the client account.
node ./mint-tokens.js $CONTRACT_DEPLOY_FULL/TestToken.json $GETH_SIGNER_ADDR 0x9F0C62Fe60b22301751d6cDe1175526b9280b965 10000000000
```

If you get a message like 

```bash
Usage: mint-tokens.js <token-hardhat-deploy-json> <signer-account> <receiver-account> <token-ammount>
```

then you need to ensure you provided all the required arguments.
In particular you need to ensure that the `GETH_SIGNER_ADDR` env variable
holds the signer address (we used
`export GETH_SIGNER_ADDR=$(cat geth_signer_address.txt)` above to
make sure it is set).

## 3. Run Codex

With accounts and geth in place, we can now start the Codex nodes.

### 3.1. Storage Node

The storage node will be the one storing data and submitting the proofs of
storage to the chain. To do that, it needs access to:

1. the address of the Marketplace contract that has been deployed to
   the local geth node in [Step 2.1](#21-deploy-the-codex-marketplace-contracts);
2. the sample ceremony files which are shipped in the Codex contracts repo
  (`nim-codex/vendor/codex-contracts-eth`).

**Address of the Marketplace Contract.** The contract address can be found
inside of the file `nim-codex/vendor/codex-contracts-eth/deployments/codexdisttestnetwork/Marketplace.json`.
We captured that location above in `CONTRACT_DEPLOY_FULL` variable, thus, from
the `marketplace-tutorial` folder just run:

```bash
grep '"address":' ${CONTRACT_DEPLOY_FULL}/Marketplace.json
```

which should print something like:
```bash
"address": "0xCf0df6C52B02201F78E8490B6D6fFf5A82fC7BCd",
```

> This address should match the address we got earlier when deploying
> the Marketplace contract above.

Then run the following with the correct market place address:
```bash
export MARKETPLACE_ADDRESS="0x0000000000000000000000000000000000000000"
echo ${MARKETPLACE_ADDRESS} > marketplace_address.txt
```

where you replace `0x0000000000000000000000000000000000000000` with
the Marketplace contract above in
[Step 2.1](#21-deploy-the-codex-marketplace-contracts).

**Prover ceremony files.** The ceremony files are under the
`nim-codex/vendor/codex-contracts-eth/verifier/networks/codexdisttestnetwork`
subdirectory. There are three of them: `proof_main.r1cs`, `proof_main.zkey`,
and `prooof_main.wasm`. We will need all of them to start the Codex storage node.

**Starting the storage node.** Let:

* `PROVER_ASSETS` contain the directory where the prover ceremony files are
  located. **This must be an absolute path**;
* `CODEX_BINARY` contain the location of your Codex binary;
* `MARKETPLACE_ADDRESS` contain the address of the Marketplace contract
  (we have already set it above).

Set these paths into environment variables (make sure you are in
the `marketplace-tutorial` directory):

```bash
export CONTRACT_DEPLOY_FULL=$(realpath "../nim-codex/vendor/codex-contracts-eth/deployments/codexdisttestnetwork")
export PROVER_ASSETS=$(realpath "../nim-codex/vendor/codex-contracts-eth/verifier/networks/codexdisttestnetwork/")
export CODEX_BINARY=$(realpath "../nim-codex/build/codex")
export MARKETPLACE_ADDRESS=$(cat marketplace_address.txt)
```
> you may notice, that we have already set the `CONTRACT_DEPLOY_FULL` variable
> above. Here, we make sure it is an absolute path.

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

We get the Signed Peer Record (SPR) of the storage node so we can bootstrap
the client node with it. To get the SPR, issue the following call:

```bash
curl -H 'Accept: text/plain' 'http://localhost:8000/api/codex/v1/spr' --write-out '\n'
```

You should get the SPR back starting with `spr:`.

Before you proceed, open new terminal, and enter `marketplace-tutorial` directory.

Next set these paths into environment variables:

```bash
# set the SPR for the storage node
export STORAGE_NODE_SPR=$(curl -H 'Accept: text/plain' 'http://localhost:8000/api/codex/v1/spr')
# basic vars
export CONTRACT_DEPLOY_FULL=$(realpath "../nim-codex/vendor/codex-contracts-eth/deployments/codexdisttestnetwork")
export CODEX_BINARY=$(realpath "../nim-codex/build/codex")
export MARKETPLACE_ADDRESS=$(cat marketplace_address.txt)
```
and then run:

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

Any storage negotiation has two sides: a buyer and a seller.
Therefore, before we can actually request storage, we must first offer
some of it for sale.

### 4.1 Sell Storage

The following request will cause the storage node to put out $50\text{MB}$
of storage for sale for $1$ hour, at a price of $1$ Codex token
per slot per second, while expressing that it's willing to take at most
a $1000$ Codex token penalty for not fulfilling its part of the contract.[^1]

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

This should return a JSON response containing an `id` (e.g. `"id": "0xb55b3bc7aac2563d5bf08ce8a177a38b5a40254bfa7ee8f9c52debbb176d44b0"`)
which identifies this storage offer.

> To make JSON responses more readable, you can try
> [jq](https://jqlang.github.io/jq/) JSON formatting utility
> by just adding `| jq` after the command.
> On macOS you can install with `brew install jq`.

To check the current storage offers for this node, you can issue:

```bash
curl 'http://localhost:8000/api/codex/v1/sales/availability'
```

or with `jq`:

```bash
curl 'http://localhost:8000/api/codex/v1/sales/availability' | jq
```

This should print a list of offers, with the one you just created figuring
among them (for our tutorial, there will be only one offer returned
at this time).

## 4.2. Buy Storage

Before we can buy storage, we must have some actual data to request
storage for. Start by uploading a small file to your client node.
On Linux (or macOS) you could, for instance, use `dd` to generate a $1M$ file:

```bash
dd if=/dev/urandom of=./data.bin bs=1M count=1
```

Assuming your file is named `data.bin`, you can upload it with:

```bash
curl --request POST http://localhost:8001/api/codex/v1/data --header 'Content-Type: application/octet-stream' --write-out '\n' -T ./data.bin
```

Once the upload completes, you should see a _Content Identifier_,
or _CID_ (e.g. `zDvZRwzm2mK7tvDzKScRLapqGdgNTLyyEBvx1TQY37J2CdWdS6Sj`)
for the uploaded file printed to the terminal.
Use that CID in the purchase request:

```bash
# make sure to replace the CID before with the CID you got in the previous step
export CID=zDvZRwzm2mK7tvDzKScRLapqGdgNTLyyEBvx1TQY37J2CdWdS6Sj
```

```bash
curl "http://localhost:8001/api/codex/v1/storage/request/${CID}" \
  --header 'Content-Type: application/octet-stream' \
  --data "{
    \"duration\": \"600\",
    \"reward\": \"1\",
    \"proofProbability\": \"3\",
    \"expiry\": \"500\",
    \"nodes\": 3,
    \"tolerance\": 1,
    \"collateral\": \"1000\"
  }" \
  --write-out '\n'
```

The parameters under `--data` say that:

1. we want to purchase storage for our file for $5$ minutes (`"duration": "600"`);
2. we are willing to pay up to $1$ token per slot per second (`"reward": "1"`)
3. our file will be split into three pieces (`"nodes": 3`). 
   Because we set `"tolerance": 1` we only need two (`nodes - tolerance`)
   pieces to rebuild the file; i.e., we can tolerate that at most one node
   stops storing our data; either due to failure or other reasons;
4. we demand `1000` tokens in collateral from storage providers for each piece.
   Since there are $3$ such pieces, there will be `3000` in total collateral
   committed by the storage provider(s) once our request is started.
5. finally, the `expiry` puts a time limit for filling all the slots by
   the storage provider(s). If slot are not filled by the `expire` interval,
   the request will timeout and fail. 

## 4.3. Track your Storage Requests

POSTing a storage request will make it available in the storage market,
and a storage node will eventually pick it up.

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
	"requestId": "0x86501e4677a728c6a8031971d09b921c3baa268af06b9f17f1b745e7dba5d330",
	"request": {
		"client": "0x9f0c62fe60b22301751d6cde1175526b9280b965",
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
			"cid": "zDvZRwzkyw1E7ABaUSmgtNEDjC7opzhUoHo99Vpvc98cDWeCs47u"
		},
		"expiry": "1711992852",
		"nonce": "0x9f5e651ecd3bf73c914f8ed0b1088869c64095c0d7bd50a38fc92ebf66ff5915",
		"id": "0x6c698cd0ad71c41982f83097d6fa75beb582924e08a658357a1cd4d7a2a6766d"
	},
	"state": "submitted",
  "error": null
}
```

Shows that a request has been submitted but has not yet been filled.
Your request will be successful once `"state"` shows `"started"`.
Anything other than that means the request has not been completely
processed yet, and an `"error"` state other than `null` means it failed.

Well, it was quite a journey, wasn't it? You can congratulate yourself for
successfully finishing the codex marketplace tutorial!

[^1]: Codex files get partitioned into pieces called "slots" and distributed
to various storage providers. The collateral refers to one such slot,
and will be slowly eaten away as the storage provider fails to deliver
timely proofs, but the actual logic is [more involved than that](https://github.com/codex-storage/codex-contracts-eth/blob/6c9f797f408608958714024b9055fcc330e3842f/contracts/Marketplace.sol#L209).
