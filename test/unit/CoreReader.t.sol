// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CoreReader} from "../../src/core/CoreReader.sol";

/// Unit tests for the failure mode that makes fake integration tests possible.
///
/// The read precompiles are node features, not bytecode. Running anywhere other
/// than HyperEVM — including under `forge test --fork-url`, which copies state
/// but not execution — leaves those addresses empty, and a `staticcall` to an
/// empty address **succeeds with zero bytes**. Decoded naively that is a zero
/// balance, indistinguishable from a real one.
///
/// This test runs on a plain local EVM precisely because that is the dangerous
/// environment, and asserts we refuse rather than invent an answer.
contract CoreReaderTest is Test {
    /// Assigned so the reverting calls below consume their return value.
    uint64 private sink;
    bool private flag;

    function test_spotBalanceRevertsWhenNotOnHyperEvm() public {
        Harness h = new Harness();
        vm.expectRevert(
            abi.encodeWithSelector(CoreReader.PrecompileEmpty.selector, CoreReader.SPOT_BALANCE)
        );
        sink = h.spotBalanceTotal(address(this), 0);
    }

    function test_coreUserExistsRevertsWhenNotOnHyperEvm() public {
        Harness h = new Harness();
        vm.expectRevert(
            abi.encodeWithSelector(CoreReader.PrecompileEmpty.selector, CoreReader.CORE_USER_EXISTS)
        );
        flag = h.coreUserExists(address(this));
    }

    /// The whole point: absent a real precompile we must not report zero.
    function test_absentPrecompileIsNotReportedAsZeroBalance() public {
        Harness h = new Harness();
        assertEq(CoreReader.SPOT_BALANCE.code.length, 0, "no code here, as expected locally");
        try h.spotBalanceTotal(address(this), 0) returns (uint64 total) {
            fail(string.concat("returned a balance of ", vm.toString(total), " from nothing"));
        } catch {}
    }
}

/// External wrapper so `vm.expectRevert` sees a call boundary.
contract Harness {
    function spotBalanceTotal(address user, uint64 token) external view returns (uint64) {
        return CoreReader.spotBalance(user, token).total;
    }

    function coreUserExists(address user) external view returns (bool) {
        return CoreReader.coreUserExists(user);
    }
}
