// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

contract ERC725XDelegateTarget {
    address public ownerSlot;

    function setOwnerSlot(address newOwner) external returns (address) {
        ownerSlot = newOwner;

        return ownerSlot;
    }
}
