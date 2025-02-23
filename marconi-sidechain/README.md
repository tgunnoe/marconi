# marconi-sidechain

`marconi-sidechain` is a lightweight chain-follower application for the Sidechain project to index and query specific information from the Cardano blockchain.
The interface for querying the indexed information uses [JSON-RPC](https://www.jsonrpc.org/specification) over HTTP.

See the [architecture documentation](./doc/ARCHITECTURE.adoc) for more information on how this application was built.

## Prerequisites

If using **Nix**:

* [Nix](https://nixos.org/download.html) (`>=2.5.1`)
* Ensure you have the following configuration (eg in `~/.config/nix/nix.conf`):

```
experimental-features = nix-command flakes
accept-flake-config = true
```

If using **Docker**:

```
docker pull nixos/nix:2.18.1
```

If *not* using **Nix** or **Docker**:

* [GHC](https://www.haskell.org/downloads/) (`==8.10.7`)
* [Cabal](https://www.haskell.org/cabal/download.html) (`>=3.4.0.0`)
* [cardano-node](https://github.com/input-output-hk/cardano-node/releases/tag/1.35.4) (`==1.35.4`) running on preview testnet, pre-production testnet or mainnet

## How to build from source

### Nix build

The `marconi-sidechain` executable is available as a nix flake.

If inside the `marconi` repository, you can run from the top-level:

```
$ nix build .#marconi-sidechain
```

Or you may run from anywhere (with or without a clone of the repo):

```
$ nix build github:input-output-hk/marconi#marconi-sidechain
```

Both commands will produce a `result` directory containing the executable
`result/bin/marconi-sidechain`.

Note that Nix builds work on Mac as well as Linux.
However, building native binaries (`aarch64-darwin`) for Apple Silicon is currently broken
so it's necessary to force an x86 build with the `--system x86_64-darwin` Nix command-line option.

### Nix+Cabal build

To build `marconi-sidechain` from the source files, use the following commands:

```sh
git clone git@github.com:input-output-hk/marconi.git
cd marconi
nix develop
cabal update # Important: updates the index-state for the cardano-haskell-packages repository (CHaP)
cabal clean # Optional, but makes sure you start clean
cabal build marconi-sidechain
```

The above process will build the executable in your local environment at this location:

```sh
cabal exec -- which marconi-sidechain
```

Or you can run the executable directly with:

```sh
cabal run marconi-sidechain:exe:marconi-sidechain -- --help
```

Note that Nix+Cabal builds work on Mac as well as Linux.
However, building native binaries (`aarch64-darwin`) for Apple Silicon is currently broken
so it's necessary to force an x86 build with the `--system x86_64-darwin` Nix command-line option.

### Docker build

Start a container and add some nix configuration:

```
$ docker run -it --name marconi nixos/nix:2.18.1
bash-5.2# mkdir -p ~/.config/nix/
bash-5.2# cat >>~/.config/nix/nix.conf <<EOF
experimental-features = nix-command flakes
accept-flake-config = true
EOF
```

Then follow the instructions for the Nix+Cabal build above.

### Cabal build

TBD

## Command line summary

Run `marconi-sidechain`, `$(cabal exec -- which marconi-sidechain) --help` or `cabal run marconi-sidechain:exe:marconi-sidechain -- --help` for a general synopsis of the command line options depending on your installation method.

See [this automatically generated golden file](./test/Spec/Golden/Cli/marconi-sidechain___help.help) for the up-to-date help command output.

## How to run

We are assuming that:

* you have a local running cardano-node instance
  * since we upgraded to v8.x, you need to use the config file available in the `config` directory of the `marconi` repository, or else you will get some Conway exceptions.
* you've set the following environment variables:
  * `CARDANO_NODE_SOCKET_PATH`: socket path of your local cardano-node instance
  * `MARCONI_DB_DIRECTORY`: directory in which to create the various SQLite database files

The most minimal way to run the executable is as follows:

```sh
$(cabal exec -- which marconi-sidechain) \
    --testnet-magic 1 \
    --socket-path "$CARDANO_NODE_SOCKET_PATH" \
    --db-dir "$MARCONI_DB_DIRECTORY" \
```

This command will do two things:

* from the last chainpoint (if none, from genesis), fetch blocks from the local node, extract required data and index them in the database.
* run a JSON-RPC server which will listen for any queries on the indexed data.

Using the `--addresses-to-index`, you can instruct `marconi-sidechain` to index target addresses.
By default, all addresses are indexed in the database.

Some example addresses from pre-production-testnet are:

```
addr_test1vpfwv0ezc5g8a4mkku8hhy3y3vp92t7s3ul8g778g5yegsgalc6gc \
addr_test1vp8cprhse9pnnv7f4l3n6pj0afq2hjm6f7r2205dz0583egagfjah \
addr_test1wpzvcmq8yuqnnzerzv0u862hmc4tc8xlm74wtsqmh56tgpc3pvx0f \
addr_test1wrn2wfykuhswv4km08w0zcl5apmnqha0j24fa287vueknasq6t4hc \
addr_test1wr9gquc23wc7h8k4chyaad268mjft7t0c08wqertwms70sc0fvx8w \
```

## Querying JSON-RPC server

There is single endpoint from which the client can send requests using a `POST` request: `/json-rpc` (or `http:localhost:3000/json-rpc`)

The body of HTTP request must contain a JSON of the following format:

```json
{ "jsonrpc": "2.0"
, "method": "<METHOD>"
, "params": "<PARAMETERS>"
, "id": 0
}
```

The `id` field should be a random ID representing your request. The response will have that same ID.

### JSON-RPC API method examples

All of the following example are actual results from the Cardano pre-production testnet.

A script that runs these examples is in `marconi-sidechain/examples/run-pre-prod-queries`.

#### echo

Healthcheck method to test that the JSON-RPC server is responding.

```sh
$ curl -d '{"jsonrpc": "2.0", "method": "echo", "params": "", "id": 0}' -H 'Content-Type: application/json' -X POST http://localhost:3000/json-rpc | jq
{
  "id": 0,
  "jsonrpc": "2.0",
  "result": []
}
```

#### getTargetAddresses

Retrieves user provided addresses.

Assuming the user started the `marconi-sidechain` executable with the address `addr_test1qz0ru2w9suwv8mcskg8r9ws3zvguekkkx6kpcnn058pe2ql2ym0y64huzhpu0wl8ewzdxya0hj0z5ejyt3g98lpu8xxs8faq0m` as the address to index.

```sh
$ curl -d '{"jsonrpc": "2.0" , "method": "getTargetAddresses" , "params": "", "id": 1}' -H 'Content-Type: application/json' -X POST http://localhost:3000/json-rpc | jq
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": ["addr_test1qz0ru2w9suwv8mcskg8r9ws3zvguekkkx6kpcnn058pe2ql2ym0y64huzhpu0wl8ewzdxya0hj0z5ejyt3g98lpu8xxs8faq0m"]
}
```

#### getCurrentSyncedBlock (PARTIALLY IMPLEMENTED)

```sh
$ curl -d '{"jsonrpc": "2.0" , "method": "getCurrentSyncedBlock" , "params": "", "id": 1}' -H 'Content-Type: application/json' -X POST http://localhost:3000/json-rpc | jq
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": {
    "blockHeaderHash": "ac12e3aa40cf6f0b48957e372daf44800199c7f4b7f0a359ed342662a8b830ff",
    "blockNo": 27655,
    "blockTimestamp": 0,
    "epochNo": 0,
    "slotNo": 638600
  }
}
```

#### getUtxosFromAddress (PARTIALLY IMPLEMENTED)

```sh
$ curl -d '{"jsonrpc": "2.0" , "method": "getUtxosFromAddress" , "params": { "address": "addr_test1vz09v9yfxguvlp0zsnrpa3tdtm7el8xufp3m5lsm7qxzclgmzkket", "unspentBeforeSlotNo": 100000000 }, "id": 1}' -H 'Content-Type: application/json' -X POST http://localhost:3000/json-rpc | jq
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": [
    {
      "address": "addr_test1vz09v9yfxguvlp0zsnrpa3tdtm7el8xufp3m5lsm7qxzclgmzkket",
      "blockHeaderHash": "affaf81ee993f657212d094c345ba86eed383a1ba19b5510e419390b85aa77a2",
      "blockNo": 21655,
      "datum": null,
      "datumHash": null,
      "slotNo": 518600,
      "spentBy": null,
      "txId": "59f68ea73b95940d443dc516702d5e5deccac2429e4d974f464cc9b26292fd9c",
      "txIndexInBlock": 0,
      "txInputs": [],
      "txIx": 0
    }
  ]
}
```

#### getBurnTokenEvents (PARTIALLY IMPLEMENTED)

```sh
curl -d  '{"jsonrpc": "2.0", "method": "getBurnTokenEvents", "params": { "afterTx":"a9279f32f7d36320b61074e7abd95651c8c01f0be2b91a06d9d3e99d00d18602", "policyId": "e2bab64ca481afc5a695b7db22fd0a7df4bf930158dfa652fb337999"}, "id": 1}' -H 'Content-Type: application/json' -X POST http://localhost:3000/json-rpc | jq
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": [
    {
      "assetName": "53554d4d495441574152445344656669",
      "blockHeaderHash": "6604093589b301e60a7fa52c68346104ab07c92c9190f1d2c01286ecb3acbd96",
      "blockNo": 178085,
      "burnAmount": 1,
      "redeemer": null,
      "redeemerHash": null,
      "slotNo": 10680629,
      "txId": "a9279f32f7d36320b61074e7abd95651c8c01f0be2b91a06d9d3e99d00d18602"
    },
    {
      "assetName": "436f696e41",
      "blockHeaderHash": "4389b62bae6452e2798f8c264f69ea09607205bf7961b86f4f822d861a282eff",
      "blockNo": 178226,
      "burnAmount": 1,
      "redeemer": null,
      "redeemerHash": null,
      "slotNo": 10683562,
      "txId": "890472618e16a09d9ce6bc048378be0150ff8848c04069f24ec60290aace48d1"
    },
    {
      "assetName": "436f696e42",
      "blockHeaderHash": "34988e3ee455d5a37edf977d8eb61ecd2761f1c5cdfda3b8a782f4cfd3b888aa",
      "blockNo": 178228,
      "burnAmount": 1,
      "redeemer": null,
      "redeemerHash": null,
      "slotNo": 10683595,
      "txId": "8c866323290381105321fd33e884fbc9989514bd9ca54507eefd8cc19bc5dedd"
    }
  ]
}

```

#### getActiveStakePoolDelegationByEpoch

```sh
$ curl -d '{"jsonrpc": "2.0" , "method": "getActiveStakePoolDelegationByEpoch" , "params": 6, "id": 1}' -H 'Content-Type: application/json' -X POST http://localhost:3000/json-rpc | jq
{
  "id": 1,
  "jsonrpc": "2.0",
  "result":
    [
        {
            "blockHeaderHash": "578f3cb70f4153e1622db792fea9005c80ff80f83df028210c7a914fb780a6f6",
            "blockNo": 64903,
            "epochNo": 6,
            "lovelace": 100000000000000,
            "poolId": "pool1z22x50lqsrwent6en0llzzs9e577rx7n3mv9kfw7udwa2rf42fa",
            "slotNo": 1382422
        },
        {
            "blockHeaderHash": "578f3cb70f4153e1622db792fea9005c80ff80f83df028210c7a914fb780a6f6",
            "blockNo": 64903,
            "epochNo": 6,
            "lovelace": 100000000000000,
            "poolId": "pool1547tew8vmuj0g6vj3k5jfddudextcw6hsk2hwgg6pkhk7lwphe6",
            "slotNo": 1382422
        },
        {
            "blockHeaderHash": "578f3cb70f4153e1622db792fea9005c80ff80f83df028210c7a914fb780a6f6",
            "blockNo": 64903,
            "epochNo": 6,
            "lovelace": 100000000000000,
            "poolId": "pool174mw7e20768e8vj4fn8y6p536n8rkzswsapwtwn354dckpjqzr8",
            "slotNo": 1382422
        }
    ]
}
```

#### getNonceByEpoch

```sh
$ curl -d '{"jsonrpc": "2.0" , "method": "getNonceByEpoch" , "params": 4, "id": 1}' -H 'Content-Type: application/json' -X POST http://localhost:3000/json-rpc | jq
{
  "id": 1,
  "jsonrpc": "2.0",
  "result":
    {
        "blockHeaderHash": "fdd5eb1b1e9fc278a08aef2f6c0fe9b576efd76966cc552d8c5a59271dc01604",
        "blockNo": 21645,
        "epochNo": 4,
        "nonce": "ce4a80f49c44c21d7114d93fe5f992a2f9de6bad4a03a5df7e7403004ebe16fc",
        "slotNo": 518400
    }
}
```

### Other documentation

See [test-json-rpc.http](./examples/run-pre-prod-queries) for additional example usages.

See [API](./doc/API.adoc) for the full API documentation.
