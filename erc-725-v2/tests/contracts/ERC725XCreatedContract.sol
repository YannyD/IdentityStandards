// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

contract ERC725XCreatedContract {
    uint256 public initialNumber;
    address public creator;
    uint256 public creationValue;

    constructor(uint256 initialNumber_) payable {
        initialNumber = initialNumber_;
        creator = msg.sender;
        creationValue = msg.value;
    }
}
