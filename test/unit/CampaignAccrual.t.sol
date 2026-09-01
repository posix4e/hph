// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Campaign} from "../../src/Campaign.sol";
import {CoreReader} from "../../src/core/CoreReader.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "./TestToken.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";

/// UNIT tests for the accrual arithmetic.
///
/// These **mock the HyperCore precompiles** with `vm.mockCall`, so they prove
/// what our own maths does with a given sequence of readings — nothing about how
/// HyperCore behaves. Anything asserting real Core behaviour belongs in the
/// integration suite against testnet, where nothing is substituted.
///
/// The rule under test exists because samples are permissionless: whoever calls
/// `sample()` chooses *when*, so the accrual must not reward timing. Accrual uses
/// `min(previous, current)` over each interval and caps intervals at `MAX_GAP`.
contract CampaignAccrualTest is Test {
    Harness campaign;
    TestToken token;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    uint64 constant START = 1_000_000;
    uint64 constant END = START + 1 days;
    uint64 constant TOKEN = 7;
    uint32 constant ASSET = 3;

    /// Campaigns are clones in production, so tests build them the same way:
    /// deploy the implementation once, clone, initialise.
    function _harness(TestToken tok, address requester) internal returns (Harness h) {
        h = Harness(Clones.clone(address(new Harness())));
        h.initialize(ASSET, IERC20(address(tok)), TOKEN, 1, START, END, requester);
    }

    function setUp() public {
        token = new TestToken();
        campaign = _harness(token, address(this));
        campaign.register(ALICE);
        campaign.register(BOB);
        _mockBbo(100, 101);
        vm.warp(START);
    }

    function _mockHold(address who, uint64 held) internal {
        vm.mockCall(
            CoreReader.SPOT_BALANCE,
            abi.encode(who, TOKEN),
            abi.encode(CoreReader.SpotBalance({total: held, hold: held, entryNtl: 0}))
        );
    }

    function _mockBbo(uint64 bid, uint64 ask) internal {
        vm.mockCall(CoreReader.BBO, abi.encode(ASSET), abi.encode(CoreReader.Bbo(bid, ask)));
    }

    /// Holding steadily across an interval accrues hold * elapsed.
    function test_steadyHoldAccruesRectangle() public {
        _mockHold(ALICE, 100);
        _mockHold(BOB, 0);
        campaign.sample();

        vm.warp(START + 60);
        campaign.sample();

        assertEq(campaign.committed(ALICE), 100 * 60);
        assertEq(campaign.committed(BOB), 0);
    }

    /// The attack the `min` rule exists to stop: hold nothing, then spike capital
    /// immediately before a sample and claim the whole preceding interval.
    function test_spikingBeforeASampleEarnsNothingForThatInterval() public {
        _mockHold(ALICE, 0);
        _mockHold(BOB, 0);
        campaign.sample();

        vm.warp(START + 60);
        _mockHold(ALICE, 1_000_000);
        campaign.sample();

        assertEq(campaign.committed(ALICE), 0, "min(0, spike) accrues nothing");
    }

    /// Symmetric case: high at the start, withdrawn before the next sample.
    function test_withdrawingBeforeASampleEarnsNothingForThatInterval() public {
        _mockHold(ALICE, 1_000_000);
        _mockHold(BOB, 0);
        campaign.sample();

        vm.warp(START + 60);
        _mockHold(ALICE, 0);
        campaign.sample();

        assertEq(campaign.committed(ALICE), 0, "min(spike, 0) accrues nothing");
    }

    /// A long unsampled stretch cannot be claimed wholesale.
    function test_intervalIsCappedAtMaxGap() public {
        _mockHold(ALICE, 10);
        _mockHold(BOB, 0);
        campaign.sample();

        vm.warp(START + 1 hours);
        campaign.sample();

        assertEq(campaign.committed(ALICE), uint256(10) * campaign.MAX_GAP());
    }

    /// Sampling frequency changes accuracy, never total. Two campaigns, same
    /// steady hold, different cadences: the one sampled more often must not pay
    /// more, or calling `sample()` in a loop would be an attack.
    function test_samplingMoreOftenDoesNotInflateScore() public {
        _mockHold(ALICE, 100);
        _mockHold(BOB, 100);

        campaign.sample();
        // forge-lint: disable-start(calls-loop)
        for (uint64 t = 1; t <= 60; t++) {
            vm.warp(START + t);
            campaign.sample();
        }
        // forge-lint: disable-end(calls-loop)
        uint256 sampledEverySecond = campaign.committed(ALICE);

        Harness sparse = _harness(token, address(this));
        sparse.register(ALICE);
        vm.warp(START);
        sparse.sample();
        vm.warp(START + 60);
        sparse.sample();

        assertEq(sampledEverySecond, sparse.committed(ALICE), "cadence must not matter");
    }

    function test_medianOfTwoIsTheirMean() public {
        _mockHold(ALICE, 100);
        _mockHold(BOB, 50);
        campaign.sample();
        vm.warp(START + 10);
        campaign.sample();

        assertEq(campaign.committed(ALICE), 1000);
        assertEq(campaign.committed(BOB), 500);
        assertEq(campaign.medianCommitted(), 750);
    }

    function test_sampleOutsideWindowReverts() public {
        vm.warp(END + 1);
        _mockHold(ALICE, 1);
        vm.expectRevert(Campaign.NotInWindow.selector);
        campaign.sample();
    }
}

/// Exposes the internal registration path; the real route is a signature batch.
contract Harness is Campaign {
    function register(address worker) external {
        _register(worker);
    }
}
