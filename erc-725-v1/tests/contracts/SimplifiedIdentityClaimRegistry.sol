// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC725V1Identity, IClaimIssuer } from "../../src/ERC725V1Identity.sol";

/// @notice Test helper that compresses identity, claim topic, and trusted issuer registries into one simplified model.
/// @dev The intent is to keep the example focused on claim issuance and verification while still using the same
///      outer shape a permissioned ERC-3643 token would normally call: `isVerified(userAddress)`.
///      The contract name intentionally avoids naming any one downstream standard: it is a simplified model for testing
///      ERC-734/735-compatible claim identities with registry-based eligibility checks.
///      This intentionally omits registry metadata such as country; jurisdiction or residence can be represented as
///      claims on the identity when the test needs them.
///      In a full ERC-3643 deployment these concerns are usually split across:
///      - IdentityRegistry / IdentityRegistryStorage: wallet -> onchain identity
///      - ClaimTopicsRegistry: claim topics required by the token
///      - TrustedIssuersRegistry: claim issuers trusted for those topics
contract SimplifiedIdentityClaimRegistry {
    uint256 internal constant SCHEME_ECDSA = 1;

    struct IdentityRecord {
        ERC725V1Identity identity;
        bool exists;
    }

    mapping(address userAddress => IdentityRecord record) internal identities;
    uint256[] internal claimTopics;
    mapping(uint256 topic => bool exists) internal claimTopicExists;
    mapping(uint256 topic => mapping(bytes32 dataHash => bool allowed)) internal allowedClaimDataHashes;
    mapping(uint256 topic => bool exists) internal allowedClaimDataHashExists;
    IClaimIssuer[] internal trustedIssuers;
    mapping(address issuer => bool exists) internal trustedIssuerExists;
    mapping(address issuer => uint256[] topics) internal trustedIssuerClaimTopics;
    mapping(address issuer => mapping(uint256 topic => bool approved)) internal trustedIssuerHasClaimTopic;

    // ERC-3643 IdentityRegistry-style registration: link an investor wallet to its ERC-725 v1 identity.
    function registerIdentity(address userAddress, ERC725V1Identity identityContract) external {
        identities[userAddress] = IdentityRecord({ identity: identityContract, exists: true });
    }

    function contains(address userAddress) external view returns (bool) {
        return identities[userAddress].exists;
    }

    function identity(address userAddress) external view returns (ERC725V1Identity) {
        return identities[userAddress].identity;
    }

    // ERC-3643 ClaimTopicsRegistry-style configuration: define which claims are required to pass `isVerified`.
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

    // Optional claim-data policy for the simplified tests, e.g. accreditation must be true and location can be in
    // a permitted set.
    function addAllowedClaimData(uint256 claimTopic, bytes calldata claimData) external {
        allowedClaimDataHashes[claimTopic][keccak256(claimData)] = true;
        allowedClaimDataHashExists[claimTopic] = true;
    }

    function removeAllowedClaimData(uint256 claimTopic, bytes calldata claimData) external {
        delete allowedClaimDataHashes[claimTopic][keccak256(claimData)];
    }

    function clearAllowedClaimDataPolicy(uint256 claimTopic) external {
        delete allowedClaimDataHashExists[claimTopic];
    }

    function isAllowedClaimData(uint256 claimTopic, bytes calldata claimData) external view returns (bool) {
        return allowedClaimDataHashes[claimTopic][keccak256(claimData)];
    }

    // ERC-3643 TrustedIssuersRegistry-style configuration: trust this issuer for the listed claim topics.
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

    /// @notice ERC-3643-shaped eligibility check used by the tests instead of a direct accreditation helper.
    /// @dev This returns true only when the registered identity has every required claim topic, and each required topic
    ///      has at least one valid claim from an issuer trusted for that topic. If the registry configured an allowed
    ///      data policy for a topic, the stored claim data must be in that allowed set.
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

    // This is the core ERC-3643 claim-validation loop, kept inline here so the repo can show the flow without deploying
    // separate registry contracts. It mirrors: identity -> getClaimIdsByTopic -> trusted issuer -> isClaimValid ->
    // data.
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

            if (_claimDataIsAllowed(claimTopic, claim.data)) {
                return true;
            }
        }

        return false;
    }

    function _claimDataIsAllowed(uint256 claimTopic, bytes memory claimData) internal view returns (bool) {
        if (!allowedClaimDataHashExists[claimTopic]) {
            return true;
        }

        return allowedClaimDataHashes[claimTopic][keccak256(claimData)];
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
