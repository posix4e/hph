// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Campaign} from "./Campaign.sol";

/// @notice Launches campaigns as minimal proxies.
///
/// A campaign deployed outright costs roughly **1.9M gas** against HyperEVM's
/// **2M** small-block limit, so every launch would need big blocks — a per-account
/// HyperCore setting that also slows every other transaction from about a second
/// to about a minute. Requiring a requester to know that, and to toggle it, to
/// post a job is not a workable product.
///
/// Cloning moves the cost to a one-time implementation deploy. Each campaign
/// after that is an EIP-1167 proxy of about 45 bytes, comfortably inside a small
/// block, and a requester never learns that block sizes exist.
///
/// The factory holds no funds, has no owner, and can do nothing to a campaign
/// once launched. It is a deployer, not an operator.
contract JobFactory {
    /// The campaign whose code every clone delegates to. Immutable here is
    /// correct: it is a property of the factory, identical for all clones.
    address public immutable implementation;

    event CampaignLaunched(
        address indexed campaign, address indexed requester, uint64 windowStart, uint64 windowEnd
    );

    constructor(address implementation_) {
        require(implementation_ != address(0), "no implementation");
        implementation = implementation_;
    }

    /// @notice Launch a campaign. Anyone may call this; no listing is granted
    /// and nobody can refuse or revoke one.
    /// @dev Cloned and initialised in a single transaction, so an uninitialised
    /// campaign is never observable.
    function launch(
        uint32 asset,
        IERC20 payoutToken,
        uint64 coreToken,
        uint256 coreUnitDivisor,
        uint64 windowStart,
        uint64 windowEnd
    ) external returns (Campaign campaign) {
        campaign = Campaign(Clones.clone(implementation));
        // Emitted before initialisation: a revert there discards the log anyway,
        // so this ordering costs nothing and leaves no window for a reordered
        // launch record.
        emit CampaignLaunched(address(campaign), msg.sender, windowStart, windowEnd);
        campaign.initialize(
            asset, payoutToken, coreToken, coreUnitDivisor, windowStart, windowEnd, msg.sender
        );
    }
}
