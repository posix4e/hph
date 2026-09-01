// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Campaign} from "../../src/Campaign.sol";
import {JobFactory} from "../../src/JobFactory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "./TestToken.sol";

/// UNIT tests for launching campaigns.
///
/// The gas assertion here is the point of the whole clone design: HyperEVM's
/// default small block allows **2,000,000** gas, and a directly deployed campaign
/// costs about 1.9M — over the limit once intrinsic and calldata costs are added.
/// That would force every requester to enable big blocks, a per-account HyperCore
/// setting that also slows their every other transaction from a second to a
/// minute.
contract FactoryTest is Test {
    /// HyperEVM's small-block gas limit.
    uint256 constant SMALL_BLOCK_GAS = 2_000_000;

    JobFactory factory;
    TestToken token;

    function setUp() public {
        factory = new JobFactory(address(new Campaign()));
        token = new TestToken();
    }

    function _launch() internal returns (Campaign) {
        return factory.launch(3, IERC20(address(token)), 7, 1, 1_000_000, 2_000_000);
    }

    /// A launch must fit in a small block with room to spare, or requesters are
    /// back to toggling block sizes to post a job.
    function test_launchFitsComfortablyInASmallBlock() public {
        uint256 before = gasleft();
        _launch();
        uint256 used = before - gasleft();

        assertLt(used, SMALL_BLOCK_GAS / 4, "a launch should be a small fraction of a block");
    }

    function test_launchedCampaignIsInitialised() public {
        Campaign c = _launch();

        assertEq(c.asset(), 3);
        assertEq(address(c.payoutToken()), address(token));
        assertEq(c.coreToken(), 7);
        assertEq(c.windowStart(), 1_000_000);
        assertEq(c.windowEnd(), 2_000_000);
        assertEq(c.requester(), address(this), "the launcher is the requester");
    }

    /// Clones share code but must not share state, or every campaign would be
    /// the same campaign.
    function test_clonesHaveIndependentState() public {
        Campaign a = _launch();
        Campaign b = factory.launch(9, IERC20(address(token)), 7, 1, 5_000_000, 6_000_000);

        assertTrue(address(a) != address(b));
        assertEq(a.asset(), 3);
        assertEq(b.asset(), 9);
        assertEq(a.windowEnd(), 2_000_000);
        assertEq(b.windowEnd(), 6_000_000);
    }

    /// Domain separation depends on `verifyingContract`, and OpenZeppelin's
    /// EIP712 caches it at construction — which happens on the implementation,
    /// not the clone. It recomputes when `address(this)` differs, and this
    /// asserts that actually holds, because a shared domain would let one
    /// signature register a worker on every campaign at once.
    function test_clonesDoNotShareAnEip712Domain() public {
        Campaign a = _launch();
        Campaign b = _launch();

        address worker = address(0xA11CE);
        assertTrue(
            a.registrationDigest(worker, 0) != b.registrationDigest(worker, 0),
            "each clone must sign under its own domain"
        );
    }

    function test_initializeCannotBeCalledTwice() public {
        Campaign c = _launch();
        vm.expectRevert(Campaign.AlreadyInitialized.selector);
        c.initialize(1, IERC20(address(token)), 1, 1, 1, 2, address(this));
    }

    /// The factory is a deployer, not an operator: it holds nothing and has no
    /// power over a campaign once launched.
    function test_factoryHoldsNoFundsAndNoAuthority() public {
        Campaign c = _launch();
        assertEq(token.balanceOf(address(factory)), 0);
        assertTrue(c.requester() != address(factory), "the factory is never the requester");
    }
}
