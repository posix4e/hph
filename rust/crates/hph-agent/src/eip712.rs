//! Signing work actions.
//!
//! A worker's only obligation is to produce a signature. This module builds the
//! EIP-712 digest the contract will verify, and the digest must match the
//! contract's byte for byte — a mismatch is silent, surfacing as "bad signature"
//! rather than as a spec disagreement, which is the sort of bug that costs a day.
//!
//! The twin assertion lives in `test/unit/Eip712Vector.t.sol`. Both sides pin the
//! same literal for the same fixed inputs, so drift in either fails exactly one
//! test.

use alloy::primitives::{Address, B256};
use alloy::sol;
use alloy::sol_types::{eip712_domain, Eip712Domain, SolStruct};

sol! {
    /// A worker's signed intent to join a job.
    ///
    /// Must stay identical to `SignedActions.Registration`, including field
    /// order: the type string is hashed into the digest, so renaming a field or
    /// swapping two of them changes every signature.
    #[derive(Debug)]
    struct Registration {
        address worker;
        uint64 deadline;
    }
}

/// The EIP-712 domain for a job.
///
/// `verifying_contract` is what stops a signature for one job being replayed
/// against another, and `chain_id` stops a testnet signature working on mainnet.
pub fn domain(chain_id: u64, campaign: Address) -> Eip712Domain {
    eip712_domain! {
        name: "hph",
        version: "1",
        chain_id: chain_id,
        verifying_contract: campaign,
    }
}

/// The digest a worker signs to register for `campaign`.
pub fn registration_digest(
    chain_id: u64,
    campaign: Address,
    worker: Address,
    deadline: u64,
) -> B256 {
    Registration { worker, deadline }.eip712_signing_hash(&domain(chain_id, campaign))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::address;

    /// The cross-language vector. The same inputs and the same literal appear in
    /// `test/unit/Eip712Vector.t.sol`; if these two ever disagree, workers are
    /// signing something the contract will reject.
    #[test]
    fn registration_digest_matches_the_solidity_vector() {
        let digest = registration_digest(
            998,
            address!("1111111111111111111111111111111111111111"),
            address!("00000000000000000000000000000000000A11cE"),
            1_900_000_000,
        );
        assert_eq!(
            digest.to_string(),
            "0x3dbd2045c4b1fdf71cec2039d52c751c65f2c64106ebad188c9455dac8c93aad"
        );
    }

    /// Domain separation, asserted rather than assumed: the same registration
    /// signed for a different job must produce a different digest.
    #[test]
    fn a_different_campaign_yields_a_different_digest() {
        let worker = address!("00000000000000000000000000000000000A11cE");
        let a = registration_digest(
            998,
            address!("1111111111111111111111111111111111111111"),
            worker,
            0,
        );
        let b = registration_digest(
            998,
            address!("2222222222222222222222222222222222222222"),
            worker,
            0,
        );
        assert_ne!(a, b);
    }

    /// And the same job on a different chain must not accept it either.
    #[test]
    fn a_different_chain_yields_a_different_digest() {
        let worker = address!("00000000000000000000000000000000000A11cE");
        let campaign = address!("1111111111111111111111111111111111111111");
        assert_ne!(
            registration_digest(998, campaign, worker, 0),
            registration_digest(999, campaign, worker, 0)
        );
    }
}
