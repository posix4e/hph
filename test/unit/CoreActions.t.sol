// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CoreActions} from "../../src/core/CoreActions.sol";

/// Unit tests for the HyperCore action wire format.
///
/// These assert our bytes against the published encoding. No HyperCore is
/// involved and none is implied: a wrong action id or a misplaced header byte
/// produces a payload the network discards *without reverting*, so byte-exact
/// assertions here are the only cheap defence.
contract CoreActionsTest is Test {
    function test_headerIsVersionThenBigEndianActionId() public pure {
        bytes memory a = CoreActions.encode(7, abi.encode(uint64(1), true));
        assertEq(uint8(a[0]), 0x01, "byte 0 is the encoding version");
        assertEq(uint8(a[1]), 0x00);
        assertEq(uint8(a[2]), 0x00);
        assertEq(uint8(a[3]), 0x07, "bytes 1-3 are the action id, big-endian");
    }

    /// The example given in the Hyperliquid docs, reproduced exactly.
    function test_usdClassTransferMatchesDocumentedExample() public pure {
        bytes memory expected =
            abi.encodePacked(bytes4(0x01000007), abi.encode(uint64(1_000_000), true));
        assertEq(CoreActions.usdClassTransfer(1_000_000, true), expected);
    }

    function test_spotSendCarriesDestinationTokenAndAmount() public pure {
        address dest = address(0xBEEF);
        bytes memory action = CoreActions.spotSend(dest, 1, 42);

        assertEq(action.length, 4 + 96, "header plus three abi words");
        assertEq(uint8(action[3]), 6, "spot send is action 6");

        bytes memory body = new bytes(action.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = action[4 + i];
        }
        (address d, uint64 token, uint64 amount) = abi.decode(body, (address, uint64, uint64));
        assertEq(d, dest);
        assertEq(token, 1);
        assertEq(amount, 42);
    }

    /// A three-byte id field cannot express an id above 2^24-1, and silently
    /// truncating one would target a different action.
    function test_actionIdIsNotTruncated() public pure {
        bytes memory a = CoreActions.encode(type(uint24).max, "");
        assertEq(uint8(a[1]), 0xFF);
        assertEq(uint8(a[2]), 0xFF);
        assertEq(uint8(a[3]), 0xFF);
    }

    /// System addresses are `0x20` then the big-endian token index. Getting this
    /// wrong sends real tokens to an address nobody controls.
    function test_systemAddressEmbedsTokenIndex() public pure {
        assertEq(
            CoreActions.systemAddress(0),
            0x2000000000000000000000000000000000000000,
            "token 0 is the bare prefix"
        );
        assertEq(CoreActions.systemAddress(1), 0x2000000000000000000000000000000000000001);
        assertEq(CoreActions.systemAddress(0x1234), 0x2000000000000000000000000000000000001234);
    }
}
