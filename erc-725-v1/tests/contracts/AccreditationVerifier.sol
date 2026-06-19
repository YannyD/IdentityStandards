// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC725V1Identity, IClaimIssuer } from "../../src/ERC725V1Identity.sol";

contract AccreditationVerifier {
    uint256 internal constant SCHEME_ECDSA = 1;

    mapping(address issuer => mapping(uint256 topic => bool approved)) public trustedIssuers;

    function setTrustedIssuer(address issuer, uint256 topic, bool approved) external {
        trustedIssuers[issuer][topic] = approved;
    }

    function isAccredited(ERC725V1Identity identity, uint256 accreditationTopic) external view returns (bool) {
        bytes32[] memory claimIds = identity.getClaimIdsByTopic(accreditationTopic);

        for (uint256 i = 0; i < claimIds.length; i++) {
            ERC725V1Identity.Claim memory claim = identity.getClaim(claimIds[i]);

            if (!trustedIssuers[claim.issuer][accreditationTopic] || claim.scheme != SCHEME_ECDSA) {
                continue;
            }

            if (!IClaimIssuer(claim.issuer).isClaimValid(address(identity), claim.topic, claim.signature, claim.data)) {
                continue;
            }

            return abi.decode(claim.data, (bool));
        }

        return false;
    }
}
