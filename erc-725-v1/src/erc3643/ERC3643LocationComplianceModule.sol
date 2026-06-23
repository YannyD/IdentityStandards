// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC725V1Identity, IClaimIssuer } from "../ERC725V1Identity.sol";
import { ERC3643IdentityRegistry } from "./ERC3643IdentityRegistry.sol";
import { ERC3643TrustedIssuersRegistry } from "./ERC3643TrustedIssuersRegistry.sol";

contract ERC3643LocationComplianceModule {
    uint256 internal constant SCHEME_ECDSA = 1;

    ERC3643IdentityRegistry public identityRegistry;
    ERC3643TrustedIssuersRegistry public trustedIssuersRegistry;
    uint256 public geographicLocationTopic;
    mapping(bytes32 locationHash => bool allowed) public allowedLocationHashes;

    constructor(
        ERC3643IdentityRegistry identities,
        ERC3643TrustedIssuersRegistry trustedIssuers,
        uint256 locationTopic
    ) {
        identityRegistry = identities;
        trustedIssuersRegistry = trustedIssuers;
        geographicLocationTopic = locationTopic;
    }

    function addAllowedLocation(bytes calldata locationData) external {
        allowedLocationHashes[keccak256(locationData)] = true;
    }

    function removeAllowedLocation(bytes calldata locationData) external {
        delete allowedLocationHashes[keccak256(locationData)];
    }

    function canTransfer(address, address to, uint256) external view returns (bool) {
        return _hasAllowedLocation(to);
    }

    function _hasAllowedLocation(address userAddress) internal view returns (bool) {
        ERC725V1Identity identityContract = identityRegistry.identity(userAddress);

        if (address(identityContract) == address(0)) {
            return false;
        }

        bytes32[] memory claimIds = identityContract.getClaimIdsByTopic(geographicLocationTopic);
        for (uint256 i = 0; i < claimIds.length; ++i) {
            ERC725V1Identity.Claim memory claim = identityContract.getClaim(claimIds[i]);

            if (
                claim.scheme != SCHEME_ECDSA
                    || !trustedIssuersRegistry.hasClaimTopic(claim.issuer, geographicLocationTopic)
            ) {
                continue;
            }

            if (!IClaimIssuer(claim.issuer)
                    .isClaimValid(address(identityContract), claim.topic, claim.signature, claim.data)) {
                continue;
            }

            if (allowedLocationHashes[keccak256(claim.data)]) {
                return true;
            }
        }

        return false;
    }
}
