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

error ERC725V1Identity_NotManagementKey(address account);
error ERC725V1Identity_InvalidClaimIssuer(address issuer);
error ERC725V1Identity_InvalidClaimSignature(address issuer, uint256 topic);
error ERC725V1Identity_ClaimDoesNotExist(bytes32 claimId);
error ERC725V1Identity_KeyDoesNotExist(bytes32 key, uint256 purpose);

contract ERC725V1Identity is IClaimIssuer {
    uint256 public constant MANAGEMENT_KEY = 1;
    uint256 public constant ACTION_KEY = 2;
    uint256 public constant CLAIM_SIGNER_KEY = 3;
    uint256 public constant ENCRYPTION_KEY = 4;

    uint256 public constant KEY_TYPE_ECDSA = 1;
    uint256 public constant SCHEME_ECDSA = 1;

    struct Key {
        uint256[] purposes;
        uint256 keyType;
        bytes32 key;
    }

    struct Claim {
        uint256 topic;
        uint256 scheme;
        address issuer;
        bytes signature;
        bytes data;
        string uri;
    }

    mapping(bytes32 key => Key keyData) internal keys;
    mapping(uint256 purpose => bytes32[] keys) internal keysByPurpose;
    mapping(bytes32 claimId => Claim claim) internal claims;
    mapping(bytes32 claimId => bool exists) internal claimExists;
    mapping(uint256 topic => bytes32[] claimIds) internal claimIdsByTopic;

    event KeyAdded(bytes32 indexed key, uint256 indexed purpose, uint256 indexed keyType);
    event KeyRemoved(bytes32 indexed key, uint256 indexed purpose, uint256 indexed keyType);
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

    constructor(address initialManagementKey) {
        _addKey(addressToKey(initialManagementKey), MANAGEMENT_KEY, KEY_TYPE_ECDSA);
    }

    modifier onlyManagementKey() {
        if (!keyHasPurpose(addressToKey(msg.sender), MANAGEMENT_KEY)) {
            revert ERC725V1Identity_NotManagementKey(msg.sender);
        }
        _;
    }

    function addressToKey(address account) public pure returns (bytes32) {
        return keccak256(abi.encode(account));
    }

    function addKey(bytes32 key, uint256 purpose, uint256 keyType) external onlyManagementKey returns (bool) {
        return _addKey(key, purpose, keyType);
    }

    function removeKey(bytes32 key, uint256 purpose) external onlyManagementKey returns (bool) {
        if (!_keyHasExactPurpose(key, purpose)) {
            revert ERC725V1Identity_KeyDoesNotExist(key, purpose);
        }

        uint256 keyType = keys[key].keyType;
        _removePurpose(keys[key].purposes, purpose);
        _removeKeyForPurpose(keysByPurpose[purpose], key);

        if (keys[key].purposes.length == 0) {
            delete keys[key];
        }

        emit KeyRemoved(key, purpose, keyType);
        return true;
    }

    function getKey(bytes32 key) external view returns (uint256[] memory purposes, uint256 keyType, bytes32 keyValue) {
        Key storage keyData = keys[key];
        return (keyData.purposes, keyData.keyType, keyData.key);
    }

    function getKeysByPurpose(uint256 purpose) external view returns (bytes32[] memory) {
        return keysByPurpose[purpose];
    }

    function keyHasPurpose(bytes32 key, uint256 purpose) public view returns (bool) {
        bool hasRequestedPurpose = _keyHasExactPurpose(key, purpose);
        bool hasManagementPurpose = purpose != MANAGEMENT_KEY && _keyHasExactPurpose(key, MANAGEMENT_KEY);

        return hasRequestedPurpose || hasManagementPurpose;
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

    function removeClaim(bytes32 claimId) external onlyManagementKey returns (bool) {
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
        return keyHasPurpose(addressToKey(signer), CLAIM_SIGNER_KEY);
    }

    function _addKey(bytes32 key, uint256 purpose, uint256 keyType) internal returns (bool) {
        if (_keyHasExactPurpose(key, purpose)) {
            return false;
        }

        if (keys[key].key == bytes32(0)) {
            keys[key].key = key;
            keys[key].keyType = keyType;
        }

        keys[key].purposes.push(purpose);
        keysByPurpose[purpose].push(key);

        emit KeyAdded(key, purpose, keyType);
        return true;
    }

    function _keyHasExactPurpose(bytes32 key, uint256 purpose) internal view returns (bool) {
        uint256[] storage purposes = keys[key].purposes;

        for (uint256 i = 0; i < purposes.length; i++) {
            if (purposes[i] == purpose) {
                return true;
            }
        }

        return false;
    }

    function _removePurpose(uint256[] storage purposes, uint256 purpose) internal {
        for (uint256 i = 0; i < purposes.length; i++) {
            if (purposes[i] == purpose) {
                purposes[i] = purposes[purposes.length - 1];
                purposes.pop();
                return;
            }
        }
    }

    function _removeKeyForPurpose(bytes32[] storage purposeKeys, bytes32 key) internal {
        for (uint256 i = 0; i < purposeKeys.length; i++) {
            if (purposeKeys[i] == key) {
                purposeKeys[i] = purposeKeys[purposeKeys.length - 1];
                purposeKeys.pop();
                return;
            }
        }
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
