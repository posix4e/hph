// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Campaign} from "../../src/Campaign.sol";
import {Settlement} from "../../src/Settlement.sol";
import {CoreReader} from "../../src/core/CoreReader.sol";
import {CoreActions} from "../../src/core/CoreActions.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "./TestToken.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";

/// UNIT tests for escrow, the credit ledger and delivery.
///
/// The HyperCore precompiles and `CoreWriter` are mocked here, so these prove the
/// ledger arithmetic and the ordering of state changes against external calls —
/// not that HyperCore accepts anything. Delivery actually landing in a spot
/// balance is an integration claim and belongs on testnet.
contract SettleTest is Test {
    Harness campaign;
    TestToken token;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant REQUESTER = address(0x9E0);

    uint64 constant START = 1_000_000;
    uint64 constant END = START + 1 days;
    uint64 constant TOKEN = 7;
    uint32 constant ASSET = 3;
    uint256 constant POOL = 1_000_000;

    /// Campaigns are clones in production, so tests build them the same way:
    /// deploy the implementation once, clone, initialise.
    function _harness(TestToken tok, address requester) internal returns (Harness h) {
        h = Harness(Clones.clone(address(new Harness())));
        h.initialize(ASSET, IERC20(address(tok)), TOKEN, 1, START, END, requester);
    }

    function setUp() public {
        token = new TestToken();
        campaign = _harness(token, REQUESTER);
        token.mint(address(this), POOL);
        assertTrue(token.approve(address(campaign), POOL));
        campaign.fund(POOL);

        campaign.register(ALICE);
        campaign.register(BOB);
        vm.mockCall(CoreReader.BBO, abi.encode(ASSET), abi.encode(CoreReader.Bbo(1, 2)));
    }

    function _hold(address who, uint64 held) internal {
        vm.mockCall(
            CoreReader.SPOT_BALANCE,
            abi.encode(who, TOKEN),
            abi.encode(CoreReader.SpotBalance({total: held, hold: held, entryNtl: 0}))
        );
    }

    /// Commit for the whole window in a 3:1 ratio, get paid in a 3:1 ratio.
    function _commit(uint64 aliceHold, uint64 bobHold) internal {
        vm.warp(START);
        _hold(ALICE, aliceHold);
        _hold(BOB, bobHold);
        campaign.sample();
        vm.warp(START + 60);
        campaign.sample();
        vm.warp(END + 1);
    }

    function test_paysProRataByCommittedCapital() public {
        _commit(300, 100);
        campaign.settle();

        assertEq(campaign.credits(ALICE), (POOL * 3) / 4);
        assertEq(campaign.credits(BOB), POOL / 4);
    }

    /// The invariant that matters: settlement neither mints nor strands value.
    /// Dust from integer division returns to the requester rather than sitting
    /// in the contract with nobody able to claim it.
    function testFuzz_everyWeiIsAccountedFor(uint32 a, uint32 b) public {
        vm.assume(a > 0 || b > 0);
        _commit(a, b);
        campaign.settle();

        uint256 total =
            campaign.credits(ALICE) + campaign.credits(BOB) + campaign.credits(REQUESTER);
        assertEq(total, POOL, "credits must sum to the pool exactly");
    }

    function test_nobodyCommittedMeansTheRequesterIsOwedItBack() public {
        _commit(0, 0);
        campaign.settle();

        assertEq(campaign.credits(REQUESTER), POOL);
        assertEq(campaign.credits(ALICE), 0);
    }

    function test_settleBeforeWindowCloseReverts() public {
        vm.warp(END);
        vm.expectRevert(Campaign.NotInWindow.selector);
        campaign.settle();
    }

    function test_settleTwiceReverts() public {
        _commit(1, 1);
        campaign.settle();
        vm.expectRevert(Settlement.AlreadySettled.selector);
        campaign.settle();
    }

    function test_deliveryBeforeSettlementReverts() public {
        vm.expectRevert(Settlement.NotSettled.selector);
        campaign.deliver(ALICE);
    }

    /// A worker with no HyperCore account cannot be delivered to — and the credit
    /// must survive the attempt rather than being spent on a delivery that Core
    /// would silently discard.
    function test_missingCoreAccountLeavesTheCreditIntact() public {
        _commit(300, 100);
        campaign.settle();
        uint256 owed = campaign.credits(ALICE);

        vm.mockCall(CoreReader.CORE_USER_EXISTS, abi.encode(ALICE), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(Settlement.NoCoreAccount.selector, ALICE));
        campaign.deliver(ALICE);

        assertEq(campaign.credits(ALICE), owed, "still owed");
    }

    /// The escape hatch pays out on HyperEVM when Core delivery is impossible.
    function test_claimOnEvmPaysTheWorker() public {
        _commit(300, 100);
        campaign.settle();
        uint256 owed = campaign.credits(ALICE);

        campaign.claimOnEvm(ALICE);

        assertEq(token.balanceOf(ALICE), owed);
        assertEq(campaign.credits(ALICE), 0);
        assertEq(campaign.paid(ALICE), owed);
    }

    /// Delivery clears the credit and moves the tokens to the token's system
    /// address, which is what credits this contract's Core balance.
    function test_deliverySendsToTheSystemAddressAndClearsTheCredit() public {
        _commit(300, 100);
        campaign.settle();
        uint256 owed = campaign.credits(ALICE);

        vm.mockCall(CoreReader.CORE_USER_EXISTS, abi.encode(ALICE), abi.encode(true));
        vm.mockCall(CoreActions.CORE_WRITER, bytes(""), bytes(""));

        campaign.deliver(ALICE);

        assertEq(token.balanceOf(CoreActions.systemAddress(TOKEN)), owed, "bridged");
        assertEq(campaign.credits(ALICE), 0);
        assertEq(campaign.paid(ALICE), owed);
    }
}

contract Harness is Campaign {
    function register(address worker) external {
        _register(worker);
    }
}
