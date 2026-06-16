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
import { ERC725XCreatedContract, ERC725XDelegateTarget, ERC725XOperationTarget } from "./contracts/index.sol";
import { ERC725YSignedClaimStore } from "../src/ERC725YSignedClaimStore.sol";
import { Utils } from "./LibUtils.sol";

contract ERC725XTest is Test {
    ERC725X internal erc725X;

    function setUp() public virtual {
        // Deploy a fresh ERC725X contract for each operation-type test.
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
        address deployedAddress = Utils._addressFromBytes(result);
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
        address expectedAddress = Utils._computeCreate2Address(address(erc725X), salt, bytecode);

        bytes memory result =
            erc725X.execute{ value: deployValue }(OPERATION_2_CREATE2, address(0), deployValue, create2Data);
        address deployedAddress = Utils._addressFromBytes(result);
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
}

contract ERC725YTest is Test {
    bytes32 internal constant INVESTOR_ACCREDITATION_STATUS_DATA_KEY =
        keccak256("identity.walletHolder.investorAccreditationStatus");
    bytes32 internal constant RESIDENCE_DATA_KEY = keccak256("identity.walletHolder.residence");
    string internal constant RESIDENCE = "Texas";

    ERC725YSignedClaimStore internal erc725Y;

    address internal wallet;
    uint256 internal walletPrivateKey;
    address internal accreditationIssuer;
    uint256 internal accreditationIssuerPrivateKey;
    address internal thirdPartyReader;
    bytes internal accreditationSignature;
    bytes internal residenceSignature;
    mapping(address signer => bool approved) internal approvedSigners;

    function setUp() public virtual {
        // Create the wallet holder, the accreditation issuer, and a reader that represents an outside verifier.
        (wallet, walletPrivateKey) = makeAddrAndKey("wallet");
        (accreditationIssuer, accreditationIssuerPrivateKey) = makeAddrAndKey("accreditationIssuer");
        thirdPartyReader = makeAddr("thirdPartyReader");

        // The third party will later compare the discovered signer against this approved-signer list.
        approvedSigners[accreditationIssuer] = true;

        // Deploy ERC725Y from the wallet so the wallet holder becomes the ERC173 owner.
        vm.prank(wallet);
        erc725Y = new ERC725YSignedClaimStore();

        // The accreditation issuer signs a claim that the wallet holder is accredited, then posts that signed data.
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

        // The wallet holder signs and posts their own residence claim.
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
        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertTrue(abi.decode(storedValue, (bool)));
        assertEq(claimKey, expectedClaimKey);
        assertEq(latestClaim.signer, accreditationIssuer);
        assertEq(latestClaim.postedBy, accreditationIssuer);
        assertEq(latestClaim.subject, wallet);
        assertEq(latestClaim.dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(latestClaim.dataValue, (bool)));
        assertEq(latestClaim.nonce, 0);
        assertEq(keccak256(latestClaim.signature), keccak256(accreditationSignature));
        assertEq(erc725Y.nonces(accreditationIssuer), 1);
    }

    function test_ThirdPartyReadsAccreditationSigner() external {
        vm.prank(thirdPartyReader);
        bytes memory storedValue = erc725Y.getData(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        vm.prank(thirdPartyReader);
        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertTrue(abi.decode(storedValue, (bool)));
        assertEq(latestClaim.signer, accreditationIssuer);
        assertTrue(approvedSigners[latestClaim.signer]);
        assertEq(latestClaim.postedBy, accreditationIssuer);
        assertEq(latestClaim.subject, wallet);
        assertEq(latestClaim.dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(latestClaim.dataValue, (bool)));
    }

    function test_SetUpStoresWalletResidence() external view {
        bytes memory storedValue = erc725Y.getData(RESIDENCE_DATA_KEY);
        bytes32 latestClaimPointerKey = erc725Y.getLatestClaimPointerKey(RESIDENCE_DATA_KEY);
        bytes32 claimKey = abi.decode(erc725Y.getData(latestClaimPointerKey), (bytes32));
        bytes32 expectedClaimKey = erc725Y.getClaimKey(wallet, wallet, RESIDENCE_DATA_KEY, keccak256(storedValue));
        ERC725YSignedClaimStore.SignedClaim memory latestClaim = erc725Y.getLatestClaim(RESIDENCE_DATA_KEY);

        assertEq(string(storedValue), RESIDENCE);
        assertEq(claimKey, expectedClaimKey);
        assertEq(latestClaim.signer, wallet);
        assertEq(latestClaim.postedBy, wallet);
        assertEq(latestClaim.subject, wallet);
        assertEq(latestClaim.dataKey, RESIDENCE_DATA_KEY);
        assertEq(string(latestClaim.dataValue), RESIDENCE);
        assertEq(latestClaim.nonce, 0);
        assertEq(keccak256(latestClaim.signature), keccak256(residenceSignature));
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
