// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { ERC725YSignedClaimStore } from "../../src/ERC725YSignedClaimStore.sol";

contract AccreditationVerifier {
    mapping(address signer => bool approved) public approvedSigners;

    function setApprovedSigner(address signer, bool approved) external {
        approvedSigners[signer] = approved;
    }

    function isAccredited(ERC725YSignedClaimStore store, bytes32 accreditationKey) external view returns (bool) {
        address[] memory signers = store.getClaimSignersByDataKey(accreditationKey);

        for (uint256 i = 0; i < signers.length; ++i) {
            if (!approvedSigners[signers[i]]) {
                continue;
            }

            ERC725YSignedClaimStore.SignedClaim memory claim = store.getClaim(accreditationKey, signers[i]);

            address recoveredSigner = ECDSA.recover(
                store.hashSetData(claim.subject, claim.dataKey, keccak256(claim.dataValue), claim.nonce),
                claim.signature
            );

            if (recoveredSigner == claim.signer && abi.decode(claim.dataValue, (bool))) {
                return true;
            }
        }

        return false;
    }
}
