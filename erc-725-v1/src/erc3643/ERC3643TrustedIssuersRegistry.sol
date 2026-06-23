// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { IClaimIssuer } from "../ERC725V1Identity.sol";

contract ERC3643TrustedIssuersRegistry {
    IClaimIssuer[] internal trustedIssuers;
    mapping(address issuer => bool trusted) public isTrustedIssuer;
    mapping(address issuer => uint256[] topics) internal trustedIssuerClaimTopics;
    mapping(address issuer => mapping(uint256 topic => bool approved)) public hasClaimTopic;

    function addTrustedIssuer(IClaimIssuer trustedIssuer, uint256[] calldata claimTopics) external {
        address issuer = address(trustedIssuer);

        if (!isTrustedIssuer[issuer]) {
            isTrustedIssuer[issuer] = true;
            trustedIssuers.push(trustedIssuer);
        }

        for (uint256 i = 0; i < claimTopics.length; ++i) {
            _setTrustedIssuerClaimTopic(issuer, claimTopics[i], true);
        }
    }

    function removeTrustedIssuer(IClaimIssuer trustedIssuer) external {
        address issuer = address(trustedIssuer);

        if (!isTrustedIssuer[issuer]) {
            return;
        }

        uint256[] storage issuerTopics = trustedIssuerClaimTopics[issuer];
        for (uint256 i = 0; i < issuerTopics.length; ++i) {
            hasClaimTopic[issuer][issuerTopics[i]] = false;
        }

        delete trustedIssuerClaimTopics[issuer];
        isTrustedIssuer[issuer] = false;
        _removeTrustedIssuer(issuer);
    }

    function updateIssuerClaimTopics(IClaimIssuer trustedIssuer, uint256[] calldata claimTopics) external {
        address issuer = address(trustedIssuer);
        uint256[] storage currentTopics = trustedIssuerClaimTopics[issuer];

        for (uint256 i = 0; i < currentTopics.length; ++i) {
            hasClaimTopic[issuer][currentTopics[i]] = false;
        }

        delete trustedIssuerClaimTopics[issuer];

        if (!isTrustedIssuer[issuer]) {
            isTrustedIssuer[issuer] = true;
            trustedIssuers.push(trustedIssuer);
        }

        for (uint256 i = 0; i < claimTopics.length; ++i) {
            _setTrustedIssuerClaimTopic(issuer, claimTopics[i], true);
        }
    }

    function getTrustedIssuers() external view returns (IClaimIssuer[] memory) {
        return trustedIssuers;
    }

    function getTrustedIssuerClaimTopics(IClaimIssuer trustedIssuer) external view returns (uint256[] memory) {
        return trustedIssuerClaimTopics[address(trustedIssuer)];
    }

    function getTrustedIssuersForClaimTopic(uint256 claimTopic) external view returns (IClaimIssuer[] memory issuers) {
        uint256 issuerCount;
        for (uint256 i = 0; i < trustedIssuers.length; ++i) {
            if (hasClaimTopic[address(trustedIssuers[i])][claimTopic]) {
                issuerCount++;
            }
        }

        issuers = new IClaimIssuer[](issuerCount);
        uint256 issuerIndex;
        for (uint256 i = 0; i < trustedIssuers.length; ++i) {
            if (hasClaimTopic[address(trustedIssuers[i])][claimTopic]) {
                issuers[issuerIndex] = trustedIssuers[i];
                issuerIndex++;
            }
        }
    }

    function _setTrustedIssuerClaimTopic(address issuer, uint256 claimTopic, bool approved) internal {
        if (hasClaimTopic[issuer][claimTopic] == approved) {
            return;
        }

        hasClaimTopic[issuer][claimTopic] = approved;

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
