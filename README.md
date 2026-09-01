# hph

HUMAN Protocol on Hyperliquid: a marketplace where work is paid trustlessly,
because **nobody scores it**.

The protocol the whitepaper describes leans on two trusted operators — a
Recording Oracle that decides what was answered and a Reputation Oracle that
decides whether it was good. This implementation removes both by moving
validation on-chain, which the whitepaper anticipated: Reputation Oracles "can be
designed to run entirely on-chain on some blockchains, because at the time they
execute, signed pointers (hashes) for all required information are available."

## How truth gets established

A job declares how its work is validated. That is the only axis that matters;
everything else — who the worker is, what the task looks like, what it pays — is
configuration.

| family | truth from | example |
|---|---|---|
| **measurement** | chain state | liquidity provided, read from fills and builder-code attribution |
| **computational** | a deterministic checker | a test suite passing, a solver agreeing |
| **consensus** | agreement, groundtruth, kappa | preference pairs, classification, rubric scores |

Workers may be human or agent; that is orthogonal to all three.

## A worker never sends a transaction

HyperCore actions are gasless — sign EIP-712 typed data, post it, validators
order it in consensus. We adopt the same model:

1. Work is **signed, not transacted**. A keypair is the only requirement.
2. **Anyone** may batch signed actions into one HyperEVM transaction. The
   launcher pays that gas, because the launcher wants the work. Submission is
   permissionless, so withholding is routable-around.
3. Settlement credits on-chain, then delivers to the worker's **HyperCore spot
   balance** — spendable, tradable and visible by logging into Hyperliquid with
   the same wallet.

Delivery is two asynchronous hops and `CoreWriter` is non-atomic, so the on-chain
credit is the source of truth and delivery is a separate retryable step. A failed
hop leaves a claimable balance.

## Layout

    src/            Solidity — everything that decides money
    test/           Foundry tests, including the ported vector corpus
    docs/vectors/   Byte-locked test vectors carried over from the Bitcoin POC
    rust/           Headless agent worker

## Build

    forge build && forge test
    cd rust && cargo build

Contracts are **immutable with no administrative pause over funds**. Upgrades are
new factory versions that jobs opt into. A bug cannot be patched in place, which
is the price of having no admin key and the reason the test corpus matters.
