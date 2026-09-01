# Deploying to HyperEVM

## Networks

|         | chain id | RPC                                          | explorer               |
| ------- | -------- | -------------------------------------------- | ---------------------- |
| testnet | 998      | `https://rpc.hyperliquid-testnet.xyz/evm`    | `testnet.purrsec.com`  |
| mainnet | 999      | `https://rpc.hyperliquid.xyz/evm`            | `purrsec.com`          |

## Big blocks are required, and the margin is thin

HyperEVM builds **small blocks** by default: a **2,000,000** gas limit, roughly one
second. Big blocks raise that to **30,000,000** at roughly one minute.

A `Campaign` deployment measures **1,903,581 gas** of execution (`forge test
--gas-report`), against 8,462 bytes of runtime code and 9,695 of initcode. Adding
the 21,000 intrinsic cost and roughly 155,000 of calldata gas for the initcode
bytes puts a real deployment transaction **over the small-block limit**.

So: **enable big blocks on the deploying account before deploying.** This is a
HyperCore account setting (`evmUserModify`, `usingBigBlocks: true`), signed and
sent to the exchange endpoint — it is not something the deployment transaction can
do for itself. A deploy attempted without it does not fail informatively; it
simply cannot be included.

### This is an argument for cloning, not for bigger blocks

One campaign per deployment at ~1.9M gas does not scale, and it puts every launch
within 5% of a hard limit. The fix is the `JobFactory` the design already calls
for, deploying **EIP-1167 minimal proxies** — roughly 45 bytes each, a few tens of
thousands of gas, comfortably inside a small block.

The cost is that clones cannot use `immutable`, so per-campaign configuration
moves to storage: slightly more expensive to read, and initialised rather than
constructed. That is the right trade for a contract meant to be deployed
repeatedly, and it should land before any campaign is launched in anger.

## Deploying

```sh
export HPH_ASSET=<perp asset index>
export HPH_PAYOUT_TOKEN=<ERC-20 address on HyperEVM>
export HPH_CORE_TOKEN=<HyperCore token index for that ERC-20>
export HPH_CORE_UNIT_DIVISOR=<10 ** (erc20Decimals - coreWeiDecimals)>
export HPH_WINDOW_SECONDS=3600

forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://rpc.hyperliquid-testnet.xyz/evm \
  --private-key $HPH_DEPLOYER_KEY \
  --broadcast
```

`HPH_CORE_UNIT_DIVISOR` converts an ERC-20 amount into HyperCore wei units and is
immutable once set. Getting it wrong misdelivers by orders of magnitude rather
than reverting, so confirm it against `tokenInfo(coreToken)` before deploying.

## Funding testnet gas

The deploying account needs testnet HYPE:

- `faucet.chainstack.com/hyperliquid-testnet-faucet` — 1 HYPE per 24h
- `faucet.quicknode.com/hyperliquid`
- `gas.zip/faucet/hyperevm` — every 12h

## What never to deploy with

The CI integration workflow uses a **dedicated throwaway testnet key**. No key
that holds mainnet value belongs in CI secrets, and no workflow that can be
triggered by a fork may read them.
