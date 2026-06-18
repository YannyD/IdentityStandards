// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { ERC725Y } from "./ERC725Y.sol";

error ERC725YSignedClaimStore_InvalidSignature(address expectedSigner, address actualSigner);
error ERC725YSignedClaimStore_InvalidSubject(address expectedSubject, address actualSubject);
error ERC725YSignedClaimStore_InvalidDataKeyController(address controller);
error ERC725YSignedClaimStore_NotDataKeyController(bytes32 dataKey, address controller, address signer);
error ERC725YSignedClaimStore_NotDataKeyControllerOrOwner(
    bytes32 dataKey, address caller, address controller, address owner
);

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
    mapping(bytes32 dataKey => address controller) public dataKeyControllers;

    event SignedClaimStored(
        bytes32 indexed claimKey,
        address indexed signer,
        address indexed postedBy,
        address subject,
        bytes32 dataKey,
        bytes dataValue
    );

    event DataKeyControllerChanged(
        bytes32 indexed dataKey, address indexed previousController, address indexed newController
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

        _assignOrCheckDataKeyController(dataKey, signer);

        nonces[signer] = nonce + 1;

        bytes32 claimKey = getClaimKey(dataKey);

        _setData(dataKey, dataValue);
        _setData(claimKey, abi.encode(signer, msg.sender, subject, dataKey, dataValue, nonce, signature));

        emit SignedClaimStored(claimKey, signer, msg.sender, subject, dataKey, dataValue);
    }

    function transferDataKeyController(bytes32 dataKey, address newController) external {
        if (newController == address(0)) {
            revert ERC725YSignedClaimStore_InvalidDataKeyController(newController);
        }

        _checkDataKeyControllerOrOwner(dataKey);
        _setDataKeyController(dataKey, newController);
    }

    function clearDataKey(bytes32 dataKey) external {
        _checkDataKeyControllerOrOwner(dataKey);

        address previousController = dataKeyControllers[dataKey];
        delete dataKeyControllers[dataKey];

        _setData(dataKey, "");
        _setData(getClaimKey(dataKey), "");

        emit DataKeyControllerChanged(dataKey, previousController, address(0));
    }

    function getClaimKey(bytes32 dataKey) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("ERC725Y.claim", dataKey));
    }

    function getLatestClaim(bytes32 dataKey) public view returns (SignedClaim memory signedClaim) {
        return _decodeSignedClaim(getData(getClaimKey(dataKey)));
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

    function _assignOrCheckDataKeyController(bytes32 dataKey, address signer) internal {
        address controller = dataKeyControllers[dataKey];

        if (controller == address(0)) {
            _setDataKeyController(dataKey, signer);
            return;
        }

        if (controller != signer) {
            revert ERC725YSignedClaimStore_NotDataKeyController(dataKey, controller, signer);
        }
    }

    function _checkDataKeyControllerOrOwner(bytes32 dataKey) internal view {
        address controller = dataKeyControllers[dataKey];
        address account = msg.sender;
        address contractOwner = owner();

        if (account != contractOwner && account != controller) {
            revert ERC725YSignedClaimStore_NotDataKeyControllerOrOwner(dataKey, account, controller, contractOwner);
        }
    }

    function _setDataKeyController(bytes32 dataKey, address newController) internal {
        address previousController = dataKeyControllers[dataKey];
        dataKeyControllers[dataKey] = newController;

        emit DataKeyControllerChanged(dataKey, previousController, newController);
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
