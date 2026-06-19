// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29;

error ECDSARecovery_InvalidSignatureLength(uint256 length);
error ECDSARecovery_InvalidSignatureS(bytes32 s);
error ECDSARecovery_InvalidSignatureV(uint8 v);
error ECDSARecovery_InvalidSignature();

library ECDSARecovery {
    bytes32 internal constant SECP256K1N_HALF = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    function recover(bytes32 digest, bytes memory signature) internal pure returns (address signer) {
        if (signature.length != 65) {
            revert ECDSARecovery_InvalidSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (uint256(s) > uint256(SECP256K1N_HALF)) {
            revert ECDSARecovery_InvalidSignatureS(s);
        }

        if (v < 27) {
            v += 27;
        }

        if (v != 27 && v != 28) {
            revert ECDSARecovery_InvalidSignatureV(v);
        }

        signer = ecrecover(digest, v, r, s);

        if (signer == address(0)) {
            revert ECDSARecovery_InvalidSignature();
        }
    }

    function toEthSignedMessageHash(bytes32 messageHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }
}
