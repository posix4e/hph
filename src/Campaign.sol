// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CoreReader} from "./core/CoreReader.sol";
import {SignedActions} from "./SignedActions.sol";
import {Settlement} from "./Settlement.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
contract Campaign is SignedActions, Settlement {
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

    uint32 public asset;
    uint64 public windowStart;
    uint64 public windowEnd;
    address public requester;

    /// Guards `initialize` against being called twice on a clone.
    bool private _initialized;

    /// Time-weighted committed capital, in `hold` units times seconds.
    mapping(address => uint256) public committed;
    /// Last observed `hold`, the left endpoint of the next interval.
    mapping(address => uint64) public lastHold;

    address[] public workers;
    mapping(address => bool) public registered;

    uint256 public medianAtSettlement;

    uint64 public lastSampleAt;
    uint32 public sampleCount;

    error NotInWindow();
    error WindowClosed();

    event Registered(address indexed worker);
    event Sampled(uint64 at, uint32 count, uint64 bid, uint64 ask);
    event Settled(uint256 totalCommitted, uint256 median);

    error AlreadyInitialized();

    /// @notice Configure a freshly cloned campaign.
    /// @dev Called once by `JobFactory` immediately after cloning, in the same
    /// transaction, so there is no window in which an uninitialised clone is
    /// reachable. The guard is belt-and-braces against a clone deployed by
    /// anything else.
    function initialize(
        uint32 asset_,
        IERC20 payoutToken_,
        uint64 coreToken_,
        uint256 coreUnitDivisor_,
        uint64 windowStart_,
        uint64 windowEnd_,
        address requester_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        require(windowEnd_ > windowStart_, "empty window");
        require(requester_ != address(0), "no requester");
        asset = asset_;
        windowStart = windowStart_;
        windowEnd = windowEnd_;
        requester = requester_;
        _initSettlement(payoutToken_, coreToken_, coreUnitDivisor_);
    }

    /// @notice Close the job and turn committed capital into credits.
    /// @dev Callable by anyone once the window has passed. Nothing here consults
    /// an operator, an oracle, or submitted data: every input was sampled by this
    /// contract from the precompiles during the window.
    ///
    /// Payment is pro-rata by committed capital. The peer median is recorded
    /// alongside it for reputation, which is where median-relative scoring
    /// belongs; making the split itself median-relative would pay a bare majority
    /// and strand everyone else, and that is a policy choice this job does not
    /// need to make.
    function settle() external {
        if (settled) revert AlreadySettled();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= windowEnd) revert NotInWindow();
        settled = true;

        uint256 n = workers.length;
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) {
            total += committed[workers[i]];
        }
        medianAtSettlement = medianCommitted();

        // Nobody committed anything: the pool is owed back, not stranded.
        if (total == 0) {
            _credit(requester, pool);
            // forge-lint: disable-next-line(reentrancy-events)
            emit Settled(0, 0);
            return;
        }

        uint256 distributed = 0;
        for (uint256 i = 0; i < n; i++) {
            address w = workers[i];
            uint256 share = (pool * committed[w]) / total;
            distributed += share;
            _credit(w, share);
        }
        // Integer division leaves dust. It returns to the requester rather than
        // sitting in the contract forever with no claim on it.
        _credit(requester, pool - distributed);
        // Settlement moves no value; it only writes the credit ledger. Nothing
        // external is called here, so log ordering cannot be manipulated.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Settled(total, medianAtSettlement);
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
