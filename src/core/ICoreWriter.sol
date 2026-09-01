// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice The system contract that carries actions from HyperEVM to HyperCore.
/// @dev Deployed by the network at a fixed address on both mainnet and testnet.
///
/// The defining property, and the reason settlement is written the way it is:
/// `sendRawAction` is **asynchronous and non-atomic**. A successful call proves
/// only that the action was *enqueued*. It executes in a later HyperCore block,
/// and if it fails there, this EVM transaction does not revert and receives no
/// notification. Order actions are additionally delayed by design.
///
/// Never treat a returning `sendRawAction` as evidence that anything happened on
/// Core.
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}
