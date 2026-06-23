// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC725V1Identity, IClaimIssuer } from "../../src/ERC725V1Identity.sol";

contract IdentityRegistry {
    uint256 internal constant SCHEME_ECDSA = 1;

    struct IdentityRecord {
        ERC725V1Identity identity;
        uint16 country;
        bool exists;
    }

    mapping(address userAddress => IdentityRecord record) internal identities;
    uint256[] internal claimTopics;
    mapping(uint256 topic => bool exists) internal claimTopicExists;
    IClaimIssuer[] internal trustedIssuers;
    mapping(address issuer => bool exists) internal trustedIssuerExists;
    mapping(address issuer => uint256[] topics) internal trustedIssuerClaimTopics;
    mapping(address issuer => mapping(uint256 topic => bool approved)) internal trustedIssuerHasClaimTopic;

    function registerIdentity(address userAddress, ERC725V1Identity identityContract, uint16 country) external {
        identities[userAddress] = IdentityRecord({ identity: identityContract, country: country, exists: true });
    }

    function contains(address userAddress) external view returns (bool) {
        return identities[userAddress].exists;
    }

    function identity(address userAddress) external view returns (ERC725V1Identity) {
        return identities[userAddress].identity;
    }

    function investorCountry(address userAddress) external view returns (uint16) {
        return identities[userAddress].country;
    }

    function addClaimTopic(uint256 claimTopic) external {
        if (claimTopicExists[claimTopic]) {
            return;
        }

        claimTopicExists[claimTopic] = true;
        claimTopics.push(claimTopic);
    }

    function removeClaimTopic(uint256 claimTopic) external {
        if (!claimTopicExists[claimTopic]) {
            return;
        }

        claimTopicExists[claimTopic] = false;
        _removeUint256(claimTopics, claimTopic);
    }

    function getClaimTopics() external view returns (uint256[] memory) {
        return claimTopics;
    }

    function addTrustedIssuer(IClaimIssuer trustedIssuer, uint256[] calldata issuerClaimTopics) external {
        address issuer = address(trustedIssuer);

        if (!trustedIssuerExists[issuer]) {
            trustedIssuerExists[issuer] = true;
            trustedIssuers.push(trustedIssuer);
        }

        for (uint256 i = 0; i < issuerClaimTopics.length; ++i) {
            _setTrustedIssuerClaimTopic(issuer, issuerClaimTopics[i], true);
        }
    }

    function removeTrustedIssuer(IClaimIssuer trustedIssuer) external {
        address issuer = address(trustedIssuer);

        if (!trustedIssuerExists[issuer]) {
            return;
        }

        uint256[] storage issuerTopics = trustedIssuerClaimTopics[issuer];
        for (uint256 i = 0; i < issuerTopics.length; ++i) {
            trustedIssuerHasClaimTopic[issuer][issuerTopics[i]] = false;
        }

        delete trustedIssuerClaimTopics[issuer];
        trustedIssuerExists[issuer] = false;
        _removeTrustedIssuer(issuer);
    }

    function updateIssuerClaimTopics(IClaimIssuer trustedIssuer, uint256[] calldata issuerClaimTopics) external {
        address issuer = address(trustedIssuer);
        uint256[] storage currentTopics = trustedIssuerClaimTopics[issuer];

        for (uint256 i = 0; i < currentTopics.length; ++i) {
            trustedIssuerHasClaimTopic[issuer][currentTopics[i]] = false;
        }

        delete trustedIssuerClaimTopics[issuer];

        if (!trustedIssuerExists[issuer]) {
            trustedIssuerExists[issuer] = true;
            trustedIssuers.push(trustedIssuer);
        }

        for (uint256 i = 0; i < issuerClaimTopics.length; ++i) {
            _setTrustedIssuerClaimTopic(issuer, issuerClaimTopics[i], true);
        }
    }

    function setTrustedIssuer(address issuer, uint256 claimTopic, bool approved) external {
        if (approved && !trustedIssuerExists[issuer]) {
            trustedIssuerExists[issuer] = true;
            trustedIssuers.push(IClaimIssuer(issuer));
        }

        _setTrustedIssuerClaimTopic(issuer, claimTopic, approved);
    }

    function getTrustedIssuers() external view returns (IClaimIssuer[] memory) {
        return trustedIssuers;
    }

    function isTrustedIssuer(address issuer) external view returns (bool) {
        return trustedIssuerExists[issuer];
    }

    function getTrustedIssuerClaimTopics(IClaimIssuer trustedIssuer) external view returns (uint256[] memory) {
        return trustedIssuerClaimTopics[address(trustedIssuer)];
    }

    function getTrustedIssuersForClaimTopic(uint256 claimTopic) external view returns (IClaimIssuer[] memory issuers) {
        uint256 issuerCount;
        for (uint256 i = 0; i < trustedIssuers.length; ++i) {
            if (trustedIssuerHasClaimTopic[address(trustedIssuers[i])][claimTopic]) {
                issuerCount++;
            }
        }

        issuers = new IClaimIssuer[](issuerCount);
        uint256 issuerIndex;
        for (uint256 i = 0; i < trustedIssuers.length; ++i) {
            if (trustedIssuerHasClaimTopic[address(trustedIssuers[i])][claimTopic]) {
                issuers[issuerIndex] = trustedIssuers[i];
                issuerIndex++;
            }
        }
    }

    function hasClaimTopic(address issuer, uint256 claimTopic) public view returns (bool) {
        return trustedIssuerHasClaimTopic[issuer][claimTopic];
    }

    function isVerified(address userAddress) external view returns (bool) {
        IdentityRecord memory record = identities[userAddress];

        if (!record.exists) {
            return false;
        }

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

            if (claim.scheme != SCHEME_ECDSA || !hasClaimTopic(claim.issuer, claimTopic)) {
                continue;
            }

            bool validClaim = IClaimIssuer(claim.issuer)
                .isClaimValid(address(identityContract), claim.topic, claim.signature, claim.data);

            if (!validClaim) {
                continue;
            }

            if (abi.decode(claim.data, (bool))) {
                return true;
            }
        }

        return false;
    }

    function _setTrustedIssuerClaimTopic(address issuer, uint256 claimTopic, bool approved) internal {
        if (trustedIssuerHasClaimTopic[issuer][claimTopic] == approved) {
            return;
        }

        trustedIssuerHasClaimTopic[issuer][claimTopic] = approved;

        if (approved) {
            trustedIssuerClaimTopics[issuer].push(claimTopic);
        } else {
            _removeUint256(trustedIssuerClaimTopics[issuer], claimTopic);
        }
    }

    function _removeTrustedIssuer(address issuer) internal {
        for (uint256 i = 0; i < trustedIssuers.length; ++i) {
            if (address(trustedIssuers[i]) == issuer) {
                trustedIssuers[i] = trustedIssuers[trustedIssuers.length - 1];
                trustedIssuers.pop();
                return;
            }
        }
    }

    function _removeUint256(uint256[] storage values, uint256 value) internal {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == value) {
                values[i] = values[values.length - 1];
                values.pop();
                return;
            }
        }
    }
}
