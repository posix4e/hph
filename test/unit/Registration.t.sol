// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Campaign} from "../../src/Campaign.sol";
import {SignedActions} from "../../src/SignedActions.sol";
import {TestToken} from "./TestToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";

/// UNIT tests for signature-gated registration.
///
/// Two properties carry the design. A worker must be able to join **holding
/// nothing but a keypair** — no gas, no balance, never sending a transaction.
/// And because anyone may submit the batch, a hostile submitter must not be able
/// to break it for everyone else.
contract RegistrationTest is Test {
    Campaign campaign;
    TestToken token;

    uint256 constant ALICE_PK = 0xA11CE;
    uint256 constant BOB_PK = 0xB0B;
    address alice;
    address bob;

    uint64 constant START = 1_000_000;
    uint64 constant END = START + 1 days;

    /// Campaigns are clones in production; tests build them the same way.
    function _campaign(address requester) internal returns (Campaign c) {
        c = Campaign(Clones.clone(address(new Campaign())));
        c.initialize(3, IERC20(address(token)), 7, 1, START, END, requester);
    }

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);
        token = new TestToken();
        campaign = _campaign(address(this));
        vm.warp(START);
    }

    function _sign(uint256 pk, address worker, uint64 deadline)
        internal
        view
        returns (SignedActions.SignedRegistration memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, campaign.registrationDigest(worker, deadline));
        return SignedActions.SignedRegistration(worker, deadline, abi.encodePacked(r, s, v));
    }

    function _one(SignedActions.SignedRegistration memory x)
        internal
        pure
        returns (SignedActions.SignedRegistration[] memory a)
    {
        a = new SignedActions.SignedRegistration[](1);
        a[0] = x;
    }

    /// The headline claim: Alice signs, a stranger submits, Alice is registered.
    /// Alice's account is never the transaction sender and holds no balance.
    function test_workerNeverSendsATransaction() public {
        address stranger = address(0x5747A);
        assertEq(alice.balance, 0, "worker funds nothing");

        vm.prank(stranger);
        campaign.registerBatch(_one(_sign(ALICE_PK, alice, 0)));

        assertTrue(campaign.registered(alice));
        assertEq(campaign.workerCount(), 1);
        assertEq(alice.balance, 0, "and still funds nothing");
    }

    /// The griefing case. Anyone may submit, so a planted bad entry must not cost
    /// honest workers their place in the batch.
    function test_oneBadSignatureDoesNotBlockTheBatch() public {
        SignedActions.SignedRegistration[] memory batch = new SignedActions.SignedRegistration[](3);
        batch[0] = _sign(ALICE_PK, alice, 0);
        batch[1] = _sign(BOB_PK, alice, 0); // Bob's key claiming to be Alice
        batch[2] = _sign(BOB_PK, bob, 0);

        vm.expectEmit(true, false, false, true);
        // Declaring an expected event, not emitting one from a contract.
        // forge-lint: disable-next-line(reentrancy-events)
        emit SignedActions.RegistrationRejected(alice, SignedActions.Reject.WrongSigner);
        campaign.registerBatch(batch);

        assertTrue(campaign.registered(alice), "honest entry survives");
        assertTrue(campaign.registered(bob), "later entry survives too");
        assertEq(campaign.workerCount(), 2);
    }

    function test_garbageSignatureIsRejectedNotReverted() public {
        SignedActions.SignedRegistration[] memory batch = new SignedActions.SignedRegistration[](1);
        batch[0] = SignedActions.SignedRegistration(alice, 0, hex"deadbeef");

        campaign.registerBatch(batch);
        assertFalse(campaign.registered(alice));
        assertEq(campaign.workerCount(), 0);
    }

    function test_expiredRegistrationIsRejected() public {
        SignedActions.SignedRegistration memory r = _sign(ALICE_PK, alice, START + 10);
        vm.warp(START + 11);
        campaign.registerBatch(_one(r));
        assertFalse(campaign.registered(alice));
    }

    function test_duplicateRegistrationIsRejectedNotReverted() public {
        campaign.registerBatch(_one(_sign(ALICE_PK, alice, 0)));
        campaign.registerBatch(_one(_sign(ALICE_PK, alice, 0)));
        assertEq(campaign.workerCount(), 1, "registered once, not twice");
    }

    /// EIP-712 binds `verifyingContract`, so a signature is worthless elsewhere.
    /// Without this, one signature would enrol a worker in every job at once.
    function test_signatureDoesNotReplayToAnotherCampaign() public {
        SignedActions.SignedRegistration memory r = _sign(ALICE_PK, alice, 0);

        Campaign other = _campaign(address(this));
        other.registerBatch(_one(r));

        assertFalse(other.registered(alice), "domain separation holds");
        campaign.registerBatch(_one(r));
        assertTrue(campaign.registered(alice), "valid on the campaign it names");
    }

    function test_registrationAfterWindowCloseReverts() public {
        SignedActions.SignedRegistration memory r = _sign(ALICE_PK, alice, 0);
        vm.warp(END);
        vm.expectRevert(Campaign.WindowClosed.selector);
        campaign.registerBatch(_one(r));
    }
}
