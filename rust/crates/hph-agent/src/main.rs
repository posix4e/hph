//! Headless worker.
//!
//! The defining constraint: this binary holds a keypair and signs EIP-712 work
//! actions. It never sends a transaction, never needs gas, and never needs a
//! funded account. Submitters batch signed actions on-chain; settlement pushes
//! payment to the worker's HyperCore spot balance.
//!
//! Nothing here yet — the contracts come first, and this crate exists so the
//! workspace is real from the start rather than bolted on later.

fn main() {
    println!("hph-agent: not yet implemented");
}
