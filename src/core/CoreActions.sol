// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICoreWriter} from "./ICoreWriter.sol";

/// @notice Encoding of HyperCore actions for `CoreWriter.sendRawAction`.
///
/// Wire format is a four-byte header followed by the standard ABI encoding of
/// the action's parameters:
///
///     byte 0      encoding version, currently 0x01
///     bytes 1..3  action id, big-endian uint24
///     bytes 4..   abi.encode(params...)
///
/// @dev Two scaling rules that look alike and are not. **Write** actions encode
/// prices and sizes as `10^8 * human value`. **Read** precompiles return prices
/// that must be divided by `10^(6 - szDecimals)` for perps, or
/// `10^(8 - szDecimals)` for spot. Conflating them misprices silently rather
/// than reverting, so the two live in different files on purpose.
library CoreActions {
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    uint8 internal constant VERSION = 0x01;

    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_VAULT_TRANSFER = 2;
    uint24 internal constant ACTION_TOKEN_DELEGATE = 3;
    uint24 internal constant ACTION_STAKING_DEPOSIT = 4;
    uint24 internal constant ACTION_STAKING_WITHDRAW = 5;
    uint24 internal constant ACTION_SPOT_SEND = 6;
    uint24 internal constant ACTION_USD_CLASS_TRANSFER = 7;
    uint24 internal constant ACTION_FINALIZE_EVM_CONTRACT = 8;
    uint24 internal constant ACTION_ADD_API_WALLET = 9;
    uint24 internal constant ACTION_CANCEL_BY_OID = 10;
    uint24 internal constant ACTION_CANCEL_BY_CLOID = 11;
    uint24 internal constant ACTION_APPROVE_BUILDER_FEE = 12;
    uint24 internal constant ACTION_SEND_ASSET = 13;

    /// @notice Frame a header and ABI-encoded body into an action payload.
    function encode(uint24 actionId, bytes memory body) internal pure returns (bytes memory) {
        return abi.encodePacked(VERSION, bytes3(actionId), body);
    }

    /// @notice Action 6: move spot balance from this contract's Core account to
    /// `destination`'s Core account.
    /// @dev This is the second hop of a payout. The first hop is an ERC-20
    /// transfer to the token's system address, which credits *this contract*
    /// because Core reads the `Transfer` event's `from`. A contract cannot
    /// credit another account's Core balance directly, which is why payout is
    /// two hops rather than one.
    function spotSend(address destination, uint64 token, uint64 amountWei)
        internal
        pure
        returns (bytes memory)
    {
        return encode(ACTION_SPOT_SEND, abi.encode(destination, token, amountWei));
    }

    /// @notice Action 7: move value between spot and perp classes.
    function usdClassTransfer(uint64 ntl, bool toPerp) internal pure returns (bytes memory) {
        return encode(ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
    }

    /// @notice Action 9: register an API (agent) wallet for this contract's account.
    function addApiWallet(address wallet, string memory name) internal pure returns (bytes memory) {
        return encode(ACTION_ADD_API_WALLET, abi.encode(wallet, name));
    }

    /// @notice Enqueue an already-encoded action.
    /// @dev Returning normally means *enqueued*, never *executed*. Callers must
    /// keep their own record of what is owed.
    function send(bytes memory action) internal {
        ICoreWriter(CORE_WRITER).sendRawAction(action);
    }

    /// @dev `0x20` followed by 39 zero nibbles is exactly `2^157`. Expressed as a
    /// shift because Solidity reads a 40-digit hex literal as an address and
    /// forbids arithmetic on it; `test_systemAddressEmbedsTokenIndex` pins the
    /// resulting bit pattern against the literal form.
    uint160 private constant SYSTEM_ADDRESS_PREFIX = uint160(1) << 157;

    /// @notice The address that bridges `token` from HyperEVM to HyperCore.
    /// @dev Format is `0x20` followed by zeros and the big-endian token index.
    /// An ERC-20 transfer here credits the **sender's** Core spot balance.
    function systemAddress(uint64 token) internal pure returns (address) {
        return address(SYSTEM_ADDRESS_PREFIX | uint160(token));
    }
}
