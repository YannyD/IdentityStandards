// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC725Y } from "../../src/ERC725Y.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

error ERC725YTest_InvalidSignature(address expectedSigner, address actualSigner);
error ERC725YTest_InvalidSubject(address expectedSubject, address actualSubject);

contract ERC725YSignedDataHarness is ERC725Y, EIP712 {
    bytes32 internal constant SET_DATA_TYPEHASH =
        keccak256("SetData(address subject,bytes32 dataKey,bytes32 dataValueHash,uint256 nonce)");

    mapping(address signer => uint256 nonce) public nonces;

    event SignedDataChanged(
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
            revert ERC725YTest_InvalidSubject(owner(), subject);
        }

        uint256 nonce = nonces[signer];
        bytes32 digest = hashSetData(subject, dataKey, keccak256(dataValue), nonce);
        address recoveredSigner = ECDSA.recover(digest, signature);

        if (recoveredSigner != signer) {
            revert ERC725YTest_InvalidSignature(signer, recoveredSigner);
        }

        nonces[signer] = nonce + 1;

        bytes32 dataValueHash = keccak256(dataValue);
        bytes32 claimKey = getClaimKey(recoveredSigner, subject, dataKey, dataValueHash);
        bytes32 latestClaimPointerKey = getLatestClaimPointerKey(dataKey);
        // solhint-disable-next-line max-line-length
        bytes memory signedData = abi.encode(recoveredSigner, msg.sender, subject, dataKey, dataValue, nonce, signature);

        _setData(dataKey, dataValue);
        _setData(claimKey, signedData);
        _setData(latestClaimPointerKey, abi.encode(claimKey));

        emit SignedDataChanged(claimKey, recoveredSigner, msg.sender, subject, dataKey, dataValue);
    }

    function getClaimKey(
        address signer,
        address subject,
        bytes32 dataKey,
        bytes32 dataValueHash
    )
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(signer, subject, dataKey, dataValueHash));
    }

    function getLatestClaimPointerKey(bytes32 dataKey) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("ERC725Y.latestClaim", dataKey));
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
}
