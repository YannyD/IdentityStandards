// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

contract ERC725XOperationTarget {
    uint256 public storedNumber;

    event NumberStored(uint256 indexed number, address indexed caller, uint256 value);

    constructor(uint256 initialNumber) payable {
        storedNumber = initialNumber;
    }

    function setNumber(uint256 newNumber) external payable returns (uint256, address, uint256) {
        storedNumber = newNumber;
        emit NumberStored(newNumber, msg.sender, msg.value);

        return (storedNumber, msg.sender, msg.value);
    }

    function readNumber() external view returns (uint256, address, uint256) {
        return (storedNumber, msg.sender, address(this).balance);
    }
}
