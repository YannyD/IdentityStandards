// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import {
    ERC725X,
    OPERATION_0_CALL,
    OPERATION_1_CREATE,
    OPERATION_2_CREATE2,
    OPERATION_3_STATICCALL,
    OPERATION_4_DELEGATECALL
} from "../src/ERC725X.sol";

contract ERC725XTest is Test {
    ERC725X internal erc725X;

    function setUp() public virtual {
        erc725X = new ERC725X();
    }

    function test_ExecuteCallForwardsValueAndMutatesTarget() external {
        ERC725XOperationTarget target = new ERC725XOperationTarget(1);
        uint256 callValue = 1 ether;

        bytes memory result = erc725X.execute{ value: callValue }(
            OPERATION_0_CALL, address(target), callValue, abi.encodeCall(ERC725XOperationTarget.setNumber, (42))
        );
        (uint256 returnedNumber, address caller, uint256 returnedValue) =
            abi.decode(result, (uint256, address, uint256));

        assertEq(returnedNumber, 42);
        assertEq(caller, address(erc725X));
        assertEq(returnedValue, callValue);
        assertEq(target.storedNumber(), 42);
        assertEq(address(target).balance, callValue);
        assertEq(address(erc725X).balance, 0);
    }

    function test_ExecuteCreateDeploysContract() external {
        uint256 initialNumber = 123;
        uint256 deployValue = 0.5 ether;
        bytes memory creationCode =
            abi.encodePacked(type(ERC725XCreatedContract).creationCode, abi.encode(initialNumber));

        bytes memory result =
            erc725X.execute{ value: deployValue }(OPERATION_1_CREATE, address(0), deployValue, creationCode);
        address deployedAddress = _addressFromBytes(result);
        ERC725XCreatedContract createdContract = ERC725XCreatedContract(deployedAddress);

        assertGt(deployedAddress.code.length, 0);
        assertEq(createdContract.initialNumber(), initialNumber);
        assertEq(createdContract.creator(), address(erc725X));
        assertEq(createdContract.creationValue(), deployValue);
        assertEq(address(createdContract).balance, deployValue);
    }

    function test_ExecuteCreate2DeploysContractAtExpectedAddress() external {
        uint256 initialNumber = 456;
        uint256 deployValue = 0.25 ether;
        bytes32 salt = keccak256("ERC725X_CREATE2_TEST");
        bytes memory bytecode = abi.encodePacked(type(ERC725XCreatedContract).creationCode, abi.encode(initialNumber));
        bytes memory create2Data = abi.encodePacked(bytecode, salt);
        address expectedAddress = _computeCreate2Address(address(erc725X), salt, bytecode);

        bytes memory result =
            erc725X.execute{ value: deployValue }(OPERATION_2_CREATE2, address(0), deployValue, create2Data);
        address deployedAddress = _addressFromBytes(result);
        ERC725XCreatedContract createdContract = ERC725XCreatedContract(deployedAddress);

        assertEq(deployedAddress, expectedAddress);
        assertGt(deployedAddress.code.length, 0);
        assertEq(createdContract.initialNumber(), initialNumber);
        assertEq(createdContract.creator(), address(erc725X));
        assertEq(createdContract.creationValue(), deployValue);
        assertEq(address(createdContract).balance, deployValue);
    }

    function test_ExecuteStaticCallReadsTargetState() external {
        uint256 targetBalance = 2 ether;
        ERC725XOperationTarget target = new ERC725XOperationTarget{ value: targetBalance }(77);

        bytes memory result = erc725X.execute(
            OPERATION_3_STATICCALL, address(target), 0, abi.encodeCall(ERC725XOperationTarget.readNumber, ())
        );
        (uint256 returnedNumber, address caller, uint256 returnedBalance) =
            abi.decode(result, (uint256, address, uint256));

        assertEq(returnedNumber, 77);
        assertEq(caller, address(erc725X));
        assertEq(returnedBalance, targetBalance);
        assertEq(target.storedNumber(), 77);
        assertEq(address(target).balance, targetBalance);
    }

    function test_ExecuteDelegateCallRunsInERC725XStorageContext() external {
        ERC725XDelegateTarget target = new ERC725XDelegateTarget();
        address newOwner = makeAddr("newOwner");

        bytes memory result = erc725X.execute(
            OPERATION_4_DELEGATECALL, address(target), 0, abi.encodeCall(ERC725XDelegateTarget.setOwnerSlot, (newOwner))
        );
        address returnedOwner = abi.decode(result, (address));

        assertEq(returnedOwner, newOwner);
        assertEq(erc725X.owner(), newOwner);
        assertEq(target.ownerSlot(), address(0));
    }

    function _computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes memory bytecode
    )
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(bytecode))))));
    }

    function _addressFromBytes(bytes memory data) internal pure returns (address account) {
        require(data.length == 20, "ERC725XTest: invalid address bytes");

        // solhint-disable-next-line no-inline-assembly
        assembly {
            account := shr(96, mload(add(data, 32)))
        }
    }
}

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

contract ERC725XCreatedContract {
    uint256 public immutable initialNumber;
    address public immutable creator;
    uint256 public immutable creationValue;

    constructor(uint256 initialNumber_) payable {
        initialNumber = initialNumber_;
        creator = msg.sender;
        creationValue = msg.value;
    }
}

contract ERC725XDelegateTarget {
    address public ownerSlot;

    function setOwnerSlot(address newOwner) external returns (address) {
        ownerSlot = newOwner;

        return ownerSlot;
    }
}
