// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// A plain ERC-20 for unit tests. Not a stand-in for HyperCore — it only stands
/// in for the payout token's EVM side, which is an ordinary ERC-20 in production
/// too.
contract TestToken is ERC20 {
    constructor() ERC20("Test USD", "TUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
