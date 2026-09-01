// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoreActions} from "./core/CoreActions.sol";
import {CoreReader} from "./core/CoreReader.sol";

/// @notice Escrow, the credit ledger, and delivery into HyperCore.
///
/// The invariant everything else defers to: **the on-chain credit is the record
/// of what a worker is owed.** Delivery to HyperCore is a separate, retryable
/// step layered on top. A credit is only cleared when value has demonstrably
/// left this contract — never merely because an action was enqueued.
///
/// @dev Delivery is two hops, because the EVM→Core bridge credits the *sender*:
/// an ERC-20 transfer to a token's system address credits **this contract's**
/// Core balance, read from the emitted `Transfer` event. A contract cannot credit
/// somebody else's Core balance directly.
///
///   1. `transfer(systemAddress(token), amount)` — this contract's Core balance
///   2. `CoreWriter` spot send — Core balance to the worker
///
/// Both may be issued in one EVM transaction because HyperCore processes
/// EVM→Core transfers **before** CoreWriter actions from the same block. Relying
/// on that ordering is the difference between a working payout and funds parked
/// in the contract's Core account.
abstract contract Settlement {
    using SafeERC20 for IERC20;

    IERC20 public immutable payoutToken;
    /// HyperCore's index for `payoutToken`.
    uint64 public immutable coreToken;
    /// Divisor converting an ERC-20 amount into Core wei units.
    /// @dev Must equal `10 ** (erc20Decimals - tokenInfo(coreToken).weiDecimals)`.
    /// Set once at construction and asserted non-zero; a wrong value misdelivers
    /// by orders of magnitude, so it is never inferred at runtime.
    uint256 public immutable coreUnitDivisor;

    uint256 public pool;
    bool public settled;

    /// What each worker is owed and has not yet received. The source of truth.
    mapping(address => uint256) public credits;
    /// What each worker has been paid, by either route.
    mapping(address => uint256) public paid;

    error AlreadySettled();
    error NotSettled();
    error NothingOwed();
    error NoCoreAccount(address worker);

    event Funded(address indexed from, uint256 amount);
    event Credited(address indexed worker, uint256 amount);
    event DeliveredToCore(address indexed worker, uint256 amount);
    event ClaimedOnEvm(address indexed worker, uint256 amount);

    constructor(IERC20 payoutToken_, uint64 coreToken_, uint256 coreUnitDivisor_) {
        require(address(payoutToken_) != address(0), "no token");
        require(coreUnitDivisor_ != 0, "no divisor");
        payoutToken = payoutToken_;
        coreToken = coreToken_;
        coreUnitDivisor = coreUnitDivisor_;
    }

    /// @notice Add to the reward pool. Anyone may fund; only the rules spend.
    function fund(uint256 amount) external {
        if (settled) revert AlreadySettled();
        pool += amount;
        emit Funded(msg.sender, amount);
        payoutToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Credits a worker during settlement. Deliberately additive so a
    /// partially-settled job cannot silently overwrite an existing debt.
    function _credit(address worker, uint256 amount) internal {
        if (amount == 0) return;
        credits[worker] += amount;
        // No external call precedes this within `_credit`; the warning comes from
        // cross-function analysis of callers that transfer elsewhere.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Credited(worker, amount);
    }

    /// @notice Push a worker's credit into their HyperCore spot balance.
    /// @dev Callable by anyone, for anyone — a worker's payout must not depend on
    /// the worker acting, or on holding gas to act with.
    function deliver(address worker) public {
        if (!settled) revert NotSettled();
        uint256 owed = credits[worker];
        if (owed == 0) revert NothingOwed();

        // A spot send to a non-existent Core account is discarded on the Core
        // side without reverting here. Checking first is what keeps the credit
        // intact instead of clearing it against a delivery that never happens.
        if (!CoreReader.coreUserExists(worker)) revert NoCoreAccount(worker);

        // Deliberate floor-then-restore: `owed` is scaled down to whole Core
        // units, and only that exact amount is spent. Dust below one Core unit
        // stays credited rather than being rounded away from the worker.
        uint256 coreAmount = owed / coreUnitDivisor;
        if (coreAmount == 0) revert NothingOwed();
        // Core amounts are uint64. Truncating here would deliver an unrelated
        // amount rather than failing, so an oversized payout is split across
        // calls instead of silently wrapping.
        if (coreAmount > type(uint64).max) coreAmount = type(uint64).max;
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 spend = coreAmount * coreUnitDivisor;

        credits[worker] = owed - spend;
        paid[worker] += spend;

        // Emitted before the external calls: a revert discards logs anyway, so
        // this ordering costs nothing and leaves no window in which a reentrant
        // token could interleave or fabricate a delivery record.
        emit DeliveredToCore(worker, spend);

        payoutToken.safeTransfer(CoreActions.systemAddress(coreToken), spend);
        // forge-lint: disable-next-line(unsafe-typecast)
        CoreActions.send(CoreActions.spotSend(worker, coreToken, uint64(coreAmount)));
    }

    /// @notice Take a credit as an ERC-20 on HyperEVM instead of on Core.
    /// @dev The escape hatch. If Core delivery is impossible — no Core account,
    /// an amount below one Core unit — the worker is still owed and can still be
    /// paid. Costs the caller gas, which is why it is not the default route.
    function claimOnEvm(address worker) external {
        if (!settled) revert NotSettled();
        uint256 owed = credits[worker];
        if (owed == 0) revert NothingOwed();

        credits[worker] = 0;
        paid[worker] += owed;
        emit ClaimedOnEvm(worker, owed);
        payoutToken.safeTransfer(worker, owed);
    }
}
