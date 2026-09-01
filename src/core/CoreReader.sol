// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Reads HyperCore state from HyperEVM through the read precompiles.
///
/// @dev These are node features, not deployed bytecode. On any chain that is not
/// HyperEVM — a local anvil, a `--fork-url` fork, a mainnet clone — the target
/// address holds no code, so a `staticcall` **succeeds and returns nothing**.
/// Left unchecked that decodes as zeros, and a test would pass while proving
/// nothing at all.
///
/// Every read here therefore asserts the returned length. Reading Core off
/// HyperEVM fails loudly, which is the only honest behaviour: a silent zero
/// balance is indistinguishable from a real one.
library CoreReader {
    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant VAULT_EQUITY = 0x0000000000000000000000000000000000000802;
    address internal constant WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant SPOT_PX = 0x0000000000000000000000000000000000000808;
    address internal constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address internal constant TOKEN_INFO = 0x000000000000000000000000000000000000080C;
    address internal constant BBO = 0x000000000000000000000000000000000000080e;
    address internal constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;

    error PrecompileFailed(address precompile);
    error PrecompileEmpty(address precompile);

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct Bbo {
        uint64 bid;
        uint64 ask;
    }

    /// @dev Reverting here aborts any loop that calls it, which is intended. A
    /// precompile failure is systemic — it means this chain is not HyperEVM, or
    /// the precompile set changed — not something wrong with one account. A
    /// per-item `continue` would let a whole sampling pass silently accrue
    /// nothing, which is the failure this library exists to prevent.
    // forge-lint: disable-next-line(require-revert-in-loop)
    function _read(address precompile, bytes memory input) private view returns (bytes memory) {
        (bool ok, bytes memory out) = precompile.staticcall(input);
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (!ok) revert PrecompileFailed(precompile);
        // An address with no code returns ok with zero bytes. That is the
        // "not actually on HyperEVM" case, and it must not read as zeros.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (out.length == 0) revert PrecompileEmpty(precompile);
        return out;
    }

    /// @notice A user's spot balance for `token`, in Core's wei units.
    function spotBalance(address user, uint64 token) internal view returns (SpotBalance memory) {
        return abi.decode(_read(SPOT_BALANCE, abi.encode(user, token)), (SpotBalance));
    }

    /// @notice The amount of `token` a user could withdraw right now.
    function withdrawable(address user, uint64 token) internal view returns (uint64) {
        return abi.decode(_read(WITHDRAWABLE, abi.encode(user, token)), (uint64));
    }

    /// @notice Whether an account exists on Core.
    /// @dev A spot send to an account that does not exist is not deliverable, so
    /// settlement checks this before spending a payout on an enqueue that will
    /// fail silently on the Core side.
    function coreUserExists(address user) internal view returns (bool) {
        return abi.decode(_read(CORE_USER_EXISTS, abi.encode(user)), (bool));
    }

    /// @notice Best bid and offer for a perp asset.
    /// @dev Raw units. See `CoreActions` for why read and write scaling differ.
    function bbo(uint32 asset) internal view returns (Bbo memory) {
        return abi.decode(_read(BBO, abi.encode(asset)), (Bbo));
    }

    /// @notice Spot mid price for an asset, in raw units.
    function spotPx(uint32 asset) internal view returns (uint64) {
        return abi.decode(_read(SPOT_PX, abi.encode(asset)), (uint64));
    }

    /// @notice HyperCore's block number, as seen from the EVM.
    function l1BlockNumber() internal view returns (uint64) {
        return abi.decode(_read(L1_BLOCK_NUMBER, ""), (uint64));
    }
}
