// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC725V1Identity, IClaimIssuer } from "../ERC725V1Identity.sol";
import { ERC3643ClaimTopicsRegistry } from "./ERC3643ClaimTopicsRegistry.sol";
import { ERC3643TrustedIssuersRegistry } from "./ERC3643TrustedIssuersRegistry.sol";

contract ERC3643IdentityRegistry {
    uint256 internal constant SCHEME_ECDSA = 1;

    struct IdentityRecord {
        ERC725V1Identity identity;
        bool exists;
    }

    ERC3643ClaimTopicsRegistry public claimTopicsRegistry;
    ERC3643TrustedIssuersRegistry public trustedIssuersRegistry;
    mapping(address userAddress => IdentityRecord record) internal identities;

    constructor(ERC3643ClaimTopicsRegistry claimTopics, ERC3643TrustedIssuersRegistry trustedIssuers) {
        claimTopicsRegistry = claimTopics;
        trustedIssuersRegistry = trustedIssuers;
    }

    function registerIdentity(address userAddress, ERC725V1Identity identityContract) external {
        identities[userAddress] = IdentityRecord({ identity: identityContract, exists: true });
    }

    function contains(address userAddress) external view returns (bool) {
        return identities[userAddress].exists;
    }

    function identity(address userAddress) external view returns (ERC725V1Identity) {
        return identities[userAddress].identity;
    }

    function isVerified(address userAddress) external view returns (bool) {
        IdentityRecord memory record = identities[userAddress];

        if (!record.exists) {
            return false;
        }

        uint256[] memory claimTopics = claimTopicsRegistry.getClaimTopics();
        for (uint256 i = 0; i < claimTopics.length; ++i) {
            if (!_hasValidClaim(record.identity, claimTopics[i])) {
                return false;
            }
        }

        return true;
    }

    function _hasValidClaim(ERC725V1Identity identityContract, uint256 claimTopic) internal view returns (bool) {
        bytes32[] memory claimIds = identityContract.getClaimIdsByTopic(claimTopic);

        for (uint256 i = 0; i < claimIds.length; ++i) {
            ERC725V1Identity.Claim memory claim = identityContract.getClaim(claimIds[i]);

            if (claim.scheme != SCHEME_ECDSA || !trustedIssuersRegistry.hasClaimTopic(claim.issuer, claimTopic)) {
                continue;
            }

            if (!IClaimIssuer(claim.issuer)
                    .isClaimValid(address(identityContract), claim.topic, claim.signature, claim.data)) {
                continue;
            }

            return true;
        }

        return false;
    }
}
