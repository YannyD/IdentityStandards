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
import {
    ERC725XCreatedContract,
    ERC725XDelegateTarget,
    ERC725XOperationTarget,
    ERC725YSignedDataHarness
} from "./contracts/index.sol";

error ERC725XTest_InvalidAddressBytes();

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

contract ERC725YTest is Test {
    bytes32 internal constant INVESTOR_ACCREDITATION_STATUS_DATA_KEY =
        keccak256("identity.walletHolder.investorAccreditationStatus");
    bytes32 internal constant RESIDENCE_DATA_KEY = keccak256("identity.walletHolder.residence");
    string internal constant RESIDENCE = "Texas";

    ERC725YSignedDataHarness internal erc725Y;

    address internal wallet;
    uint256 internal walletPrivateKey;
    address internal accreditationIssuer;
    uint256 internal accreditationIssuerPrivateKey;
    address internal thirdPartyReader;
    bytes internal accreditationSignature;
    bytes internal residenceSignature;
    mapping(address signer => bool approved) internal approvedSigners;

    function setUp() public virtual {
        (wallet, walletPrivateKey) = makeAddrAndKey("wallet");
        (accreditationIssuer, accreditationIssuerPrivateKey) = makeAddrAndKey("accreditationIssuer");
        thirdPartyReader = makeAddr("thirdPartyReader");
        approvedSigners[accreditationIssuer] = true;

        vm.prank(wallet);
        erc725Y = new ERC725YSignedDataHarness();

        bytes memory accreditationStatus = abi.encode(true);
        accreditationSignature = _signSetData(
            accreditationIssuerPrivateKey,
            accreditationIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            accreditationStatus
        );

        vm.prank(accreditationIssuer);
        erc725Y.setDataWithSignature(
            accreditationIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            accreditationStatus,
            accreditationSignature
        );

        bytes memory residence = bytes(RESIDENCE);
        residenceSignature = _signSetData(walletPrivateKey, wallet, wallet, RESIDENCE_DATA_KEY, residence);

        vm.prank(wallet);
        erc725Y.setDataWithSignature(wallet, wallet, RESIDENCE_DATA_KEY, residence, residenceSignature);
    }

    function test_SetUpDeploysERC725YTiedToWallet() external view {
        assertEq(erc725Y.owner(), wallet);
    }

    function test_SetUpStoresInvestorAccreditationStatus() external view {
        bytes memory storedValue = erc725Y.getData(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        bytes32 latestClaimPointerKey = erc725Y.getLatestClaimPointerKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        bytes32 claimKey = abi.decode(erc725Y.getData(latestClaimPointerKey), (bytes32));
        bytes32 expectedClaimKey = erc725Y.getClaimKey(
            accreditationIssuer, wallet, INVESTOR_ACCREDITATION_STATUS_DATA_KEY, keccak256(storedValue)
        );
        bytes memory claimValue = erc725Y.getData(claimKey);
        (
            address signer,
            address postedBy,
            address subject,
            bytes32 dataKey,
            bytes memory dataValue,
            uint256 nonce,
            bytes memory signature
        ) = abi.decode(claimValue, (address, address, address, bytes32, bytes, uint256, bytes));

        assertTrue(abi.decode(storedValue, (bool)));
        assertEq(claimKey, expectedClaimKey);
        assertEq(signer, accreditationIssuer);
        assertEq(postedBy, accreditationIssuer);
        assertEq(subject, wallet);
        assertEq(dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(dataValue, (bool)));
        assertEq(nonce, 0);
        assertEq(keccak256(signature), keccak256(accreditationSignature));
        assertEq(erc725Y.nonces(accreditationIssuer), 1);
    }

    function test_ThirdPartyReadsAccreditationSigner() external {
        vm.prank(thirdPartyReader);
        bytes memory storedValue = erc725Y.getData(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        bytes32 latestClaimPointerKey = erc725Y.getLatestClaimPointerKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        vm.prank(thirdPartyReader);
        bytes32 claimKey = abi.decode(erc725Y.getData(latestClaimPointerKey), (bytes32));

        vm.prank(thirdPartyReader);
        bytes memory claimValue = erc725Y.getData(claimKey);

        (address signer, address postedBy, address subject, bytes32 dataKey, bytes memory dataValue,,) =
            abi.decode(claimValue, (address, address, address, bytes32, bytes, uint256, bytes));

        assertTrue(abi.decode(storedValue, (bool)));
        assertEq(signer, accreditationIssuer);
        assertTrue(approvedSigners[signer]);
        assertEq(postedBy, accreditationIssuer);
        assertEq(subject, wallet);
        assertEq(dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(dataValue, (bool)));
    }

    function test_SetUpStoresWalletResidence() external view {
        bytes memory storedValue = erc725Y.getData(RESIDENCE_DATA_KEY);
        bytes32 latestClaimPointerKey = erc725Y.getLatestClaimPointerKey(RESIDENCE_DATA_KEY);
        bytes32 claimKey = abi.decode(erc725Y.getData(latestClaimPointerKey), (bytes32));
        bytes32 expectedClaimKey = erc725Y.getClaimKey(wallet, wallet, RESIDENCE_DATA_KEY, keccak256(storedValue));
        bytes memory claimValue = erc725Y.getData(claimKey);
        (
            address signer,
            address postedBy,
            address subject,
            bytes32 dataKey,
            bytes memory dataValue,
            uint256 nonce,
            bytes memory signature
        ) = abi.decode(claimValue, (address, address, address, bytes32, bytes, uint256, bytes));

        assertEq(string(storedValue), RESIDENCE);
        assertEq(claimKey, expectedClaimKey);
        assertEq(signer, wallet);
        assertEq(postedBy, wallet);
        assertEq(subject, wallet);
        assertEq(dataKey, RESIDENCE_DATA_KEY);
        assertEq(string(dataValue), RESIDENCE);
        assertEq(nonce, 0);
        assertEq(keccak256(signature), keccak256(residenceSignature));
        assertEq(erc725Y.nonces(wallet), 1);
    }

    function _signSetData(
        uint256 signerPrivateKey,
        address signer,
        address subject,
        bytes32 dataKey,
        bytes memory dataValue
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = erc725Y.hashSetData(subject, dataKey, keccak256(dataValue), erc725Y.nonces(signer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }
}

error ERC725YTest_InvalidSignature(address expectedSigner, address actualSigner);
error ERC725YTest_InvalidSubject(address expectedSubject, address actualSubject);
