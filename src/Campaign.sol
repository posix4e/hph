// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CoreReader} from "./core/CoreReader.sol";
import {SignedActions} from "./SignedActions.sol";

/// @notice A measurement-validated job: pays for capital committed to a market
/// over a window, scored from state the contract reads itself.
///
/// No operator scores anything. There is no admin, no pause, and no path by which
/// anyone moves escrowed funds outside the settlement rules.
///
/// @dev Scoring is a **conservative** time-weighted integral of
/// `SpotBalance.hold` — the portion of a worker's spot balance locked in resting
/// orders. A contract cannot read fills or open orders, so committed capital is
/// the closest observable proxy for liquidity provision. It cannot see the price
/// level of those orders, so a worker resting far from mid scores like a worker
/// quoting tightly. That gap is real and deliberately unclosed here; closing it
/// needs either a reporter or volume-based rewards, and both are worse.
contract Campaign is SignedActions {
    /// Samples are taken by whoever bothers, so the accrual rule must not reward
    /// *when* you sample. Two properties make that true:
    ///
    ///  - accrual uses `min(previousHold, currentHold)`, so spiking capital at
    ///    either endpoint of an interval buys nothing; a worker must hold across
    ///    the whole interval to be paid for it.
    ///  - each interval is capped at `MAX_GAP`, so a long unsampled stretch
    ///    cannot be claimed wholesale on the strength of one reading.
    ///
    /// Total accrued time is bounded by the window regardless of sample count, so
    /// sampling more often only improves accuracy — it never inflates a score.
    uint64 public constant MAX_GAP = 5 minutes;

    uint32 public immutable asset;
    uint64 public immutable coreToken;
    uint64 public immutable windowStart;
    uint64 public immutable windowEnd;
    address public immutable requester;

    /// Time-weighted committed capital, in `hold` units times seconds.
    mapping(address => uint256) public committed;
    /// Last observed `hold`, the left endpoint of the next interval.
    mapping(address => uint64) public lastHold;

    address[] public workers;
    mapping(address => bool) public registered;

    uint64 public lastSampleAt;
    uint32 public sampleCount;

    error NotInWindow();
    error WindowClosed();

    event Registered(address indexed worker);
    event Sampled(uint64 at, uint32 count, uint64 bid, uint64 ask);

    constructor(
        uint32 asset_,
        uint64 coreToken_,
        uint64 windowStart_,
        uint64 windowEnd_,
        address requester_
    ) {
        require(windowEnd_ > windowStart_, "empty window");
        require(requester_ != address(0), "no requester");
        asset = asset_;
        coreToken = coreToken_;
        windowStart = windowStart_;
        windowEnd = windowEnd_;
        requester = requester_;
    }

    function workerCount() external view returns (uint256) {
        return workers.length;
    }

    /// @notice Admit workers from a batch of signatures they produced offline.
    /// @dev Callable by anyone. Invalid entries are skipped and reported rather
    /// than reverting: submission is permissionless, so a single planted bad
    /// signature must not be able to block every honest worker in the batch.
    function registerBatch(SignedRegistration[] calldata regs) external {
        // Checked once, outside the loop: a closed window invalidates every
        // entry equally, so reverting is correct and cannot be used to grief.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= windowEnd) revert WindowClosed();
        uint256 n = regs.length;
        for (uint256 i = 0; i < n; i++) {
            SignedRegistration calldata r = regs[i];
            Reject why = _checkRegistration(r);
            if (why == Reject.None && registered[r.worker]) why = Reject.Duplicate;
            if (why != Reject.None) {
                emit RegistrationRejected(r.worker, why);
                continue;
            }
            _register(r.worker);
        }
    }

    /// @dev Registration is internal so the only route in is a verified signature
    /// batch. A worker never sends a transaction. Deliberately free of reverts:
    /// callers validate first, so one rejected entry cannot abort a batch.
    function _register(address worker) internal {
        registered[worker] = true;
        workers.push(worker);
        emit Registered(worker);
    }

    /// @notice Read Core state now and accrue committed capital since the last
    /// sample. Callable by anyone, at any frequency, during the window.
    /// @dev Reads come from the precompiles directly; nothing is passed in, so
    /// there is nothing for a caller to lie about. `CoreReader` reverts rather
    /// than returning zeros when the precompiles are absent, so this cannot
    /// silently accrue nothing on a non-HyperEVM chain.
    function sample() external {
        // `uint64` seconds runs to roughly year 584 billion, so this cast cannot
        // truncate for any chain that will ever exist.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs < windowStart || nowTs > windowEnd) revert NotInWindow();

        uint64 elapsed = lastSampleAt == 0 ? 0 : nowTs - lastSampleAt;
        if (elapsed > MAX_GAP) elapsed = MAX_GAP;

        uint256 n = workers.length;
        for (uint256 i = 0; i < n; i++) {
            address w = workers[i];
            uint64 held = CoreReader.spotBalance(w, coreToken).hold;
            if (elapsed != 0) {
                uint64 prev = lastHold[w];
                uint64 lower = held < prev ? held : prev;
                committed[w] += uint256(lower) * elapsed;
            }
            lastHold[w] = held;
        }

        lastSampleAt = nowTs;
        sampleCount++;

        CoreReader.Bbo memory q = CoreReader.bbo(asset);
        emit Sampled(nowTs, sampleCount, q.bid, q.ask);
    }

    /// @notice Each worker's score relative to the peer median.
    /// @dev Scoring against the median of the same window is what separates skill
    /// from luck: it controls for market conditions every participant shared,
    /// the same way chance-correction does for agreement. An absolute bar would
    /// pay everyone in a good window and nobody in a bad one.
    function medianCommitted() public view returns (uint256) {
        uint256 n = workers.length;
        if (n == 0) return 0;
        uint256[] memory v = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            v[i] = committed[workers[i]];
        }
        // Insertion sort: worker counts here are tens, not thousands.
        for (uint256 i = 1; i < n; i++) {
            uint256 x = v[i];
            uint256 j = i;
            while (j > 0 && v[j - 1] > x) {
                v[j] = v[j - 1];
                j--;
            }
            v[j] = x;
        }
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
    }
}
