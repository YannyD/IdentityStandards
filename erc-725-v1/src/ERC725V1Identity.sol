// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29;

import { ECDSARecovery } from "./ECDSARecovery.sol";

interface IClaimIssuer {
    function isClaimValid(
        address identity,
        uint256 topic,
        bytes calldata signature,
        bytes calldata data
    )
        external
        view
        returns (bool);
}

error ERC725V1Identity_NotOwner(address account);
error ERC725V1Identity_InvalidClaimIssuer(address issuer);
error ERC725V1Identity_InvalidClaimSigner(address signer);
error ERC725V1Identity_InvalidClaimSignature(address issuer, uint256 topic);
error ERC725V1Identity_ClaimDoesNotExist(bytes32 claimId);

contract ERC725V1Identity is IClaimIssuer {
    uint256 public constant SCHEME_ECDSA = 1;

    struct Claim {
        uint256 topic;
        uint256 scheme;
        address issuer;
        bytes signature;
        bytes data;
        string uri;
    }

    address public owner;

    mapping(bytes32 claimId => Claim claim) internal claims;
    mapping(bytes32 claimId => bool exists) internal claimExists;
    mapping(uint256 topic => bytes32[] claimIds) internal claimIdsByTopic;
    mapping(address signer => bool approved) internal claimSigners;

    event ClaimSignerAdded(address indexed signer);
    event ClaimSignerRemoved(address indexed signer);
    event ClaimAdded(
        bytes32 indexed claimId,
        uint256 indexed topic,
        address indexed issuer,
        uint256 scheme,
        bytes signature,
        bytes data,
        string uri
    );
    event ClaimChanged(
        bytes32 indexed claimId,
        uint256 indexed topic,
        address indexed issuer,
        uint256 scheme,
        bytes signature,
        bytes data,
        string uri
    );
    event ClaimRemoved(bytes32 indexed claimId, uint256 indexed topic, address indexed issuer);

    constructor(address initialOwner) {
        owner = initialOwner;
        _addClaimSigner(initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert ERC725V1Identity_NotOwner(msg.sender);
        }
        _;
    }

    function addClaimSigner(address signer) external onlyOwner returns (bool) {
        return _addClaimSigner(signer);
    }

    function removeClaimSigner(address signer) external onlyOwner returns (bool) {
        if (!claimSigners[signer]) {
            return false;
        }

        claimSigners[signer] = false;
        emit ClaimSignerRemoved(signer);
        return true;
    }

    function isClaimSigner(address signer) public view returns (bool) {
        return claimSigners[signer];
    }

    function addClaim(
        uint256 topic,
        uint256 scheme,
        address issuer,
        bytes memory signature,
        bytes memory data,
        string memory uri
    )
        external
        returns (bytes32 claimId)
    {
        if (issuer.code.length == 0) {
            revert ERC725V1Identity_InvalidClaimIssuer(issuer);
        }

        if (!IClaimIssuer(issuer).isClaimValid(address(this), topic, signature, data)) {
            revert ERC725V1Identity_InvalidClaimSignature(issuer, topic);
        }

        claimId = getClaimId(issuer, topic);
        bool isNewClaim = !claimExists[claimId];

        claims[claimId] =
            Claim({ topic: topic, scheme: scheme, issuer: issuer, signature: signature, data: data, uri: uri });

        if (isNewClaim) {
            claimExists[claimId] = true;
            claimIdsByTopic[topic].push(claimId);
            emit ClaimAdded(claimId, topic, issuer, scheme, signature, data, uri);
        } else {
            emit ClaimChanged(claimId, topic, issuer, scheme, signature, data, uri);
        }
    }

    function removeClaim(bytes32 claimId) external onlyOwner returns (bool) {
        if (!claimExists[claimId]) {
            revert ERC725V1Identity_ClaimDoesNotExist(claimId);
        }

        Claim memory claim = claims[claimId];
        delete claims[claimId];
        delete claimExists[claimId];
        _removeClaimIdForTopic(claimIdsByTopic[claim.topic], claimId);

        emit ClaimRemoved(claimId, claim.topic, claim.issuer);
        return true;
    }

    function getClaim(bytes32 claimId) external view returns (Claim memory) {
        return claims[claimId];
    }

    function getClaimIdsByTopic(uint256 topic) external view returns (bytes32[] memory) {
        return claimIdsByTopic[topic];
    }

    function getClaimId(address issuer, uint256 topic) public pure returns (bytes32) {
        return keccak256(abi.encode(issuer, topic));
    }

    function getClaimHash(address identity, uint256 topic, bytes memory data) public pure returns (bytes32) {
        return keccak256(abi.encode(identity, topic, data));
    }

    function getClaimDigest(address identity, uint256 topic, bytes memory data) public pure returns (bytes32) {
        return ECDSARecovery.toEthSignedMessageHash(getClaimHash(identity, topic, data));
    }

    function recoverClaimSigner(
        address identity,
        uint256 topic,
        bytes memory signature,
        bytes memory data
    )
        public
        pure
        returns (address)
    {
        return ECDSARecovery.recover(getClaimDigest(identity, topic, data), signature);
    }

    function isClaimValid(
        address identity,
        uint256 topic,
        bytes calldata signature,
        bytes calldata data
    )
        external
        view
        returns (bool)
    {
        address signer = recoverClaimSigner(identity, topic, signature, data);
        return claimSigners[signer];
    }

    function _addClaimSigner(address signer) internal returns (bool) {
        if (signer == address(0)) {
            revert ERC725V1Identity_InvalidClaimSigner(signer);
        }

        if (claimSigners[signer]) {
            return false;
        }

        claimSigners[signer] = true;
        emit ClaimSignerAdded(signer);
        return true;
    }

    function _removeClaimIdForTopic(bytes32[] storage topicClaimIds, bytes32 claimId) internal {
        for (uint256 i = 0; i < topicClaimIds.length; i++) {
            if (topicClaimIds[i] == claimId) {
                topicClaimIds[i] = topicClaimIds[topicClaimIds.length - 1];
                topicClaimIds.pop();
                return;
            }
        }
    }
}
