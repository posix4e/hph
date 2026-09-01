// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/// @notice Verification for work actions a worker signs but never submits.
///
/// The property this exists to guarantee: **a worker needs a keypair and nothing
/// else.** No gas, no HYPE, no funded account, no transaction. They sign an
/// EIP-712 message; anyone at all batches it on-chain. The submitter pays the gas
/// because the submitter wants the work done.
///
/// Because submission is open to anyone, a submitter must not be able to grief.
/// A malformed or expired entry is **skipped and reported**, never allowed to
/// revert a whole batch — otherwise one bad signature, planted by anyone, would
/// block every honest worker in the same call.
abstract contract SignedActions is EIP712 {
    bytes32 private constant REGISTRATION_TYPEHASH =
        keccak256("Registration(address worker,uint64 deadline)");

    /// A worker's signed intent to join this job.
    /// @dev The EIP-712 domain binds `verifyingContract`, so a signature for one
    /// job cannot be replayed against another, and `chainId` stops a testnet
    /// signature being replayed on mainnet.
    struct SignedRegistration {
        address worker;
        uint64 deadline;
        bytes signature;
    }

    enum Reject {
        None,
        Expired,
        BadSignature,
        WrongSigner,
        Duplicate
    }

    event RegistrationRejected(address indexed worker, Reject reason);

    constructor() EIP712("hph", "1") {}

    /// @notice The digest a worker signs to register.
    /// @dev Exposed so a client can be tested against the contract's own view of
    /// the digest rather than a reimplementation that might drift.
    function registrationDigest(address worker, uint64 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REGISTRATION_TYPEHASH, worker, deadline)));
    }

    /// @dev Returns the rejection reason, or `Reject.None` when the signature is
    /// valid and unexpired. Never reverts, so a caller can decide what to do with
    /// a bad entry rather than losing the batch.
    function _checkRegistration(SignedRegistration calldata r) internal view returns (Reject) {
        // forge-lint: disable-next-line(block-timestamp)
        if (r.deadline != 0 && block.timestamp > r.deadline) return Reject.Expired;

        (address recovered, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(registrationDigest(r.worker, r.deadline), r.signature);
        if (err != ECDSA.RecoverError.NoError) return Reject.BadSignature;
        if (recovered != r.worker) return Reject.WrongSigner;
        return Reject.None;
    }
}
