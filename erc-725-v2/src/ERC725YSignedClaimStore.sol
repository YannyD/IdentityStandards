// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { ERC725Y } from "./ERC725Y.sol";

error ERC725YSignedClaimStore_InvalidSignature(address expectedSigner, address actualSigner);
error ERC725YSignedClaimStore_InvalidSubject(address expectedSubject, address actualSubject);

contract ERC725YSignedClaimStore is ERC725Y, EIP712 {
    bytes32 internal constant SET_DATA_TYPEHASH =
        keccak256("SetData(address subject,bytes32 dataKey,bytes32 dataValueHash,uint256 nonce)");

    struct SignedClaim {
        address signer;
        address postedBy;
        address subject;
        bytes32 dataKey;
        bytes dataValue;
        uint256 nonce;
        bytes signature;
    }

    mapping(address signer => uint256 nonce) public nonces;
    mapping(bytes32 dataKey => address[] signers) internal signersByDataKey;
    mapping(bytes32 dataKey => mapping(address signer => bool exists)) internal signerExistsForDataKey;

    event SignedClaimStored(
        bytes32 indexed claimKey,
        address indexed signer,
        address indexed postedBy,
        address subject,
        bytes32 dataKey,
        bytes dataValue
    );

    constructor() EIP712("ERC725Y", "1") { }

    function setDataWithSignature(
        address signer,
        address subject,
        bytes32 dataKey,
        bytes memory dataValue,
        bytes memory signature
    )
        external
    {
        if (subject != owner()) {
            revert ERC725YSignedClaimStore_InvalidSubject(owner(), subject);
        }

        uint256 nonce = nonces[signer];
        bytes32 digest = hashSetData(subject, dataKey, keccak256(dataValue), nonce);
        address recoveredSigner = ECDSA.recover(digest, signature);

        if (recoveredSigner != signer) {
            revert ERC725YSignedClaimStore_InvalidSignature(signer, recoveredSigner);
        }

        nonces[signer] = nonce + 1;

        bytes32 claimKey = getClaimKey(dataKey, signer);

        _indexClaimSigner(dataKey, signer);
        _setData(claimKey, abi.encode(signer, msg.sender, subject, dataKey, dataValue, nonce, signature));

        emit SignedClaimStored(claimKey, signer, msg.sender, subject, dataKey, dataValue);
    }

    function getClaimKey(bytes32 dataKey, address signer) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("ERC725Y.claim", dataKey, signer));
    }

    function getClaim(bytes32 dataKey, address signer) public view returns (SignedClaim memory signedClaim) {
        return _decodeSignedClaim(getData(getClaimKey(dataKey, signer)));
    }

    function getClaimSignersByDataKey(bytes32 dataKey) public view returns (address[] memory) {
        return signersByDataKey[dataKey];
    }

    function hasClaimSignerForDataKey(bytes32 dataKey, address signer) public view returns (bool) {
        return signerExistsForDataKey[dataKey][signer];
    }

    function hashSetData(
        address subject,
        bytes32 dataKey,
        bytes32 dataValueHash,
        uint256 nonce
    )
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(SET_DATA_TYPEHASH, subject, dataKey, dataValueHash, nonce));

        return _hashTypedDataV4(structHash);
    }

    function _indexClaimSigner(bytes32 dataKey, address signer) internal {
        if (signerExistsForDataKey[dataKey][signer]) {
            return;
        }

        signerExistsForDataKey[dataKey][signer] = true;
        signersByDataKey[dataKey].push(signer);
    }

    function _decodeSignedClaim(bytes memory claimValue) internal pure returns (SignedClaim memory signedClaim) {
        (
            signedClaim.signer,
            signedClaim.postedBy,
            signedClaim.subject,
            signedClaim.dataKey,
            signedClaim.dataValue,
            signedClaim.nonce,
            signedClaim.signature
        ) = abi.decode(claimValue, (address, address, address, bytes32, bytes, uint256, bytes));
    }
}
