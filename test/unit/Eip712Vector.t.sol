// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Campaign} from "../../src/Campaign.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "./TestToken.sol";

/// The cross-implementation vector for signed work actions.
///
/// The Rust client and this contract must derive **byte-identical** EIP-712
/// digests, or a worker signs something the contract will never accept — and the
/// failure is silent, looking like a bad signature rather than a spec drift.
///
/// Both sides pin the same literal for the same fixed inputs. The twin assertion
/// lives in `rust/crates/hph-agent/src/eip712.rs`. Change the struct, the domain,
/// or the type string on either side and exactly one of these tests fails.
contract Eip712VectorTest is Test {
    /// Testnet, so the vector is usable against a real deployment.
    uint256 constant CHAIN_ID = 998;
    address constant VERIFYING_CONTRACT = 0x1111111111111111111111111111111111111111;
    address constant WORKER = 0x00000000000000000000000000000000000A11cE;
    uint64 constant DEADLINE = 1_900_000_000;

    function test_registrationDigestMatchesTheCrossLanguageVector() public {
        vm.chainId(CHAIN_ID);

        TestToken token = new TestToken();
        Campaign impl =
            new Campaign(3, IERC20(address(token)), 7, 1, 1_000_000, 2_000_000, address(this));
        // Place the campaign at a fixed address so `verifyingContract` — part of
        // the domain, and therefore part of the digest — is pinned too.
        vm.etch(VERIFYING_CONTRACT, address(impl).code);

        bytes32 digest = Campaign(VERIFYING_CONTRACT).registrationDigest(WORKER, DEADLINE);

        assertEq(
            digest,
            0x3dbd2045c4b1fdf71cec2039d52c751c65f2c64106ebad188c9455dac8c93aad,
            "digest must match the Rust vector"
        );
    }
}
