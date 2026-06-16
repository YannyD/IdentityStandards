// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC725YSignedClaimStore } from "../../src/ERC725YSignedClaimStore.sol";

contract AccreditationVerifier {
    mapping(address signer => bool approved) public approvedSigners;

    function setApprovedSigner(address signer, bool approved) external {
        approvedSigners[signer] = approved;
    }

    function isAccredited(ERC725YSignedClaimStore store, bytes32 accreditationKey) external view returns (bool) {
        ERC725YSignedClaimStore.SignedClaim memory latestClaim = store.getLatestClaim(accreditationKey);

        if (!approvedSigners[latestClaim.signer]) {
            return false;
        }

        return abi.decode(latestClaim.dataValue, (bool));
    }
}
