// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

error ERC725XTest_InvalidAddressBytes();

library Utils {
function _computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes memory bytecode
    )
        internal
        pure
        returns (address)
    {
        bytes32 bytecodeHash = keccak256(bytecode);
        bytes32 addressHash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash));

        return address(uint160(uint256(addressHash)));
    }

    function _addressFromBytes(bytes memory data) internal pure returns (address account) {
        if (data.length != 20) revert ERC725XTest_InvalidAddressBytes();

        // solhint-disable-next-line no-inline-assembly
        assembly {
            account := shr(96, mload(add(data, 32)))
        }
    }

   
}

