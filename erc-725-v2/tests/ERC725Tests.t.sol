// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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
    AccreditationVerifier,
    ERC725XCreatedContract,
    ERC725XDelegateTarget,
    ERC725XOperationTarget
} from "./contracts/index.sol";
import {
    ERC725YSignedClaimStore,
    ERC725YSignedClaimStore_InvalidDataKeyController,
    ERC725YSignedClaimStore_InvalidSignature,
    ERC725YSignedClaimStore_InvalidSubject,
    ERC725YSignedClaimStore_NotDataKeyController,
    ERC725YSignedClaimStore_NotDataKeyControllerOrOwner
} from "../src/ERC725YSignedClaimStore.sol";
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
    AccreditationVerifier internal accreditationVerifier;

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
        accreditationVerifier = new AccreditationVerifier();
        accreditationVerifier.setApprovedSigner(accreditationIssuer, true);

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
        bytes32 claimKey = erc725Y.getClaimKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertTrue(abi.decode(storedValue, (bool)));
        assertGt(erc725Y.getData(claimKey).length, 0);
        assertEq(latestClaim.signer, accreditationIssuer);
        assertEq(latestClaim.postedBy, accreditationIssuer);
        assertEq(latestClaim.subject, wallet);
        assertEq(latestClaim.dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(latestClaim.dataValue, (bool)));
        assertEq(latestClaim.nonce, 0);
        assertEq(keccak256(latestClaim.signature), keccak256(accreditationSignature));
        assertEq(erc725Y.dataKeyControllers(INVESTOR_ACCREDITATION_STATUS_DATA_KEY), accreditationIssuer);
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
        assertEq(keccak256(latestClaim.dataValue), keccak256(storedValue));
        assertEq(
            ECDSA.recover(
                erc725Y.hashSetData(
                    latestClaim.subject, latestClaim.dataKey, keccak256(latestClaim.dataValue), latestClaim.nonce
                ),
                latestClaim.signature
            ),
            latestClaim.signer
        );
        assertTrue(approvedSigners[latestClaim.signer]);
        assertEq(latestClaim.postedBy, accreditationIssuer);
        assertEq(latestClaim.subject, wallet);
        assertEq(latestClaim.dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(latestClaim.dataValue, (bool)));
    }

    function test_VerifierAcceptsApprovedAccreditationSigner() external view {
        assertTrue(accreditationVerifier.isAccredited(erc725Y, INVESTOR_ACCREDITATION_STATUS_DATA_KEY));
    }

    function test_UnapprovedSignerCannotOverwriteControlledAccreditationKey() external {
        (address unapprovedIssuer, uint256 unapprovedIssuerPrivateKey) = makeAddrAndKey("unapprovedIssuer");
        bytes memory accreditationStatus = abi.encode(true);
        bytes memory unapprovedSignature = _signSetData(
            unapprovedIssuerPrivateKey,
            unapprovedIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            accreditationStatus
        );

        vm.prank(unapprovedIssuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC725YSignedClaimStore_NotDataKeyController.selector,
                INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
                accreditationIssuer,
                unapprovedIssuer
            )
        );
        erc725Y.setDataWithSignature(
            unapprovedIssuer, wallet, INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationStatus, unapprovedSignature
        );

        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertTrue(abi.decode(latestClaim.dataValue, (bool)));
        assertEq(latestClaim.signer, accreditationIssuer);
        assertTrue(accreditationVerifier.isAccredited(erc725Y, INVESTOR_ACCREDITATION_STATUS_DATA_KEY));
    }

    function test_SetDataWithSignatureRejectsClaimForDifferentSubject() external {
        address wrongSubject = makeAddr("wrongSubject");
        bytes memory accreditationStatus = abi.encode(true);
        bytes memory signature = _signSetData(
            accreditationIssuerPrivateKey,
            accreditationIssuer,
            wrongSubject,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            accreditationStatus
        );

        vm.prank(accreditationIssuer);
        vm.expectRevert(abi.encodeWithSelector(ERC725YSignedClaimStore_InvalidSubject.selector, wallet, wrongSubject));
        erc725Y.setDataWithSignature(
            accreditationIssuer, wrongSubject, INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationStatus, signature
        );
    }

    function test_ControllerCanTransferDataKeyControl() external {
        (address replacementIssuer, uint256 replacementIssuerPrivateKey) = makeAddrAndKey("replacementIssuer");

        vm.prank(accreditationIssuer);
        erc725Y.transferDataKeyController(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, replacementIssuer);

        bytes memory updatedAccreditationStatus = abi.encode(false);
        bytes memory replacementSignature = _signSetData(
            replacementIssuerPrivateKey,
            replacementIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            updatedAccreditationStatus
        );

        vm.prank(replacementIssuer);
        erc725Y.setDataWithSignature(
            replacementIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            updatedAccreditationStatus,
            replacementSignature
        );

        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertEq(erc725Y.dataKeyControllers(INVESTOR_ACCREDITATION_STATUS_DATA_KEY), replacementIssuer);
        assertEq(latestClaim.signer, replacementIssuer);
        assertFalse(abi.decode(latestClaim.dataValue, (bool)));
    }

    function test_TransferDataKeyControllerRejectsZeroAddress() external {
        vm.prank(accreditationIssuer);
        vm.expectRevert(abi.encodeWithSelector(ERC725YSignedClaimStore_InvalidDataKeyController.selector, address(0)));
        erc725Y.transferDataKeyController(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, address(0));
    }

    function test_NonControllerCannotTransferDataKeyControl() external {
        address unauthorizedCaller = makeAddr("unauthorizedControllerCaller");
        address replacementIssuer = makeAddr("replacementIssuer");

        vm.prank(unauthorizedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC725YSignedClaimStore_NotDataKeyControllerOrOwner.selector,
                INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
                unauthorizedCaller,
                accreditationIssuer,
                wallet
            )
        );
        erc725Y.transferDataKeyController(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, replacementIssuer);
    }

    function test_OwnerCanDelegateDataKeyControl() external {
        (address delegatedIssuer, uint256 delegatedIssuerPrivateKey) = makeAddrAndKey("delegatedIssuer");

        vm.prank(wallet);
        erc725Y.transferDataKeyController(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, delegatedIssuer);

        bytes memory updatedAccreditationStatus = abi.encode(false);
        bytes memory delegatedSignature = _signSetData(
            delegatedIssuerPrivateKey,
            delegatedIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            updatedAccreditationStatus
        );

        vm.prank(delegatedIssuer);
        erc725Y.setDataWithSignature(
            delegatedIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            updatedAccreditationStatus,
            delegatedSignature
        );

        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertEq(erc725Y.dataKeyControllers(INVESTOR_ACCREDITATION_STATUS_DATA_KEY), delegatedIssuer);
        assertEq(latestClaim.signer, delegatedIssuer);
        assertFalse(abi.decode(latestClaim.dataValue, (bool)));
    }

    function test_ControllerCanClearDataKeySoNewSignerCanClaimControl() external {
        (address replacementIssuer, uint256 replacementIssuerPrivateKey) = makeAddrAndKey("replacementIssuer");

        bytes32 clearedClaimKey = erc725Y.getClaimKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        vm.prank(accreditationIssuer);
        erc725Y.clearDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertEq(erc725Y.getData(INVESTOR_ACCREDITATION_STATUS_DATA_KEY).length, 0);
        assertEq(erc725Y.getData(clearedClaimKey).length, 0);
        assertEq(erc725Y.dataKeyControllers(INVESTOR_ACCREDITATION_STATUS_DATA_KEY), address(0));

        bytes memory replacementAccreditationStatus = abi.encode(true);
        bytes memory replacementSignature = _signSetData(
            replacementIssuerPrivateKey,
            replacementIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            replacementAccreditationStatus
        );

        vm.prank(replacementIssuer);
        erc725Y.setDataWithSignature(
            replacementIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            replacementAccreditationStatus,
            replacementSignature
        );

        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertEq(erc725Y.dataKeyControllers(INVESTOR_ACCREDITATION_STATUS_DATA_KEY), replacementIssuer);
        assertEq(latestClaim.signer, replacementIssuer);
        assertTrue(abi.decode(latestClaim.dataValue, (bool)));
    }

    function test_OwnerCanClearDataKeySoNewSignerCanClaimControl() external {
        (address replacementIssuer, uint256 replacementIssuerPrivateKey) = makeAddrAndKey("ownerReplacementIssuer");

        vm.prank(wallet);
        erc725Y.clearDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertEq(erc725Y.getData(INVESTOR_ACCREDITATION_STATUS_DATA_KEY).length, 0);
        assertEq(erc725Y.dataKeyControllers(INVESTOR_ACCREDITATION_STATUS_DATA_KEY), address(0));

        bytes memory replacementAccreditationStatus = abi.encode(true);
        bytes memory replacementSignature = _signSetData(
            replacementIssuerPrivateKey,
            replacementIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            replacementAccreditationStatus
        );

        vm.prank(replacementIssuer);
        erc725Y.setDataWithSignature(
            replacementIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            replacementAccreditationStatus,
            replacementSignature
        );

        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertEq(erc725Y.dataKeyControllers(INVESTOR_ACCREDITATION_STATUS_DATA_KEY), replacementIssuer);
        assertEq(latestClaim.signer, replacementIssuer);
        assertTrue(abi.decode(latestClaim.dataValue, (bool)));
    }

    function test_NonControllerCannotClearDataKey() external {
        address unauthorizedCaller = makeAddr("unauthorizedClearCaller");

        vm.prank(unauthorizedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC725YSignedClaimStore_NotDataKeyControllerOrOwner.selector,
                INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
                unauthorizedCaller,
                accreditationIssuer,
                wallet
            )
        );
        erc725Y.clearDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
    }

    function test_SetDataWithSignatureRejectsTamperedValue() external {
        bytes memory signedAccreditationStatus = abi.encode(true);
        bytes memory tamperedAccreditationStatus = abi.encode(false);
        bytes memory signature = _signSetData(
            accreditationIssuerPrivateKey,
            accreditationIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            signedAccreditationStatus
        );

        vm.prank(accreditationIssuer);
        vm.expectPartialRevert(ERC725YSignedClaimStore_InvalidSignature.selector);
        erc725Y.setDataWithSignature(
            accreditationIssuer, wallet, INVESTOR_ACCREDITATION_STATUS_DATA_KEY, tamperedAccreditationStatus, signature
        );
    }

    function test_SetDataWithSignatureRejectsReplay() external {
        vm.prank(accreditationIssuer);
        vm.expectPartialRevert(ERC725YSignedClaimStore_InvalidSignature.selector);
        erc725Y.setDataWithSignature(
            accreditationIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            abi.encode(true),
            accreditationSignature
        );
    }

    function test_UpdatedAccreditationClaimSupersedesOldClaim() external {
        bytes32 claimKey = erc725Y.getClaimKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        bytes32 oldStoredClaimHash = keccak256(erc725Y.getData(claimKey));
        ERC725YSignedClaimStore.SignedClaim memory oldClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        bytes memory updatedAccreditationStatus = abi.encode(false);
        bytes memory updatedSignature = _signSetData(
            accreditationIssuerPrivateKey,
            accreditationIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            updatedAccreditationStatus
        );

        vm.prank(accreditationIssuer);
        erc725Y.setDataWithSignature(
            accreditationIssuer,
            wallet,
            INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
            updatedAccreditationStatus,
            updatedSignature
        );

        bytes memory updatedStoredValue = erc725Y.getData(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory latestClaim =
            erc725Y.getLatestClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);

        assertTrue(abi.decode(oldClaim.dataValue, (bool)));
        assertNotEq(keccak256(erc725Y.getData(claimKey)), oldStoredClaimHash);
        assertFalse(abi.decode(updatedStoredValue, (bool)));
        assertGt(erc725Y.getData(claimKey).length, 0);
        assertFalse(abi.decode(latestClaim.dataValue, (bool)));
        assertEq(latestClaim.nonce, 1);
        assertEq(erc725Y.nonces(accreditationIssuer), 2);
        assertFalse(accreditationVerifier.isAccredited(erc725Y, INVESTOR_ACCREDITATION_STATUS_DATA_KEY));
    }

    function test_SetUpStoresWalletResidence() external view {
        bytes memory storedValue = erc725Y.getData(RESIDENCE_DATA_KEY);
        bytes32 claimKey = erc725Y.getClaimKey(RESIDENCE_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory latestClaim = erc725Y.getLatestClaim(RESIDENCE_DATA_KEY);

        assertEq(string(storedValue), RESIDENCE);
        assertGt(erc725Y.getData(claimKey).length, 0);
        assertEq(latestClaim.signer, wallet);
        assertEq(latestClaim.postedBy, wallet);
        assertEq(latestClaim.subject, wallet);
        assertEq(latestClaim.dataKey, RESIDENCE_DATA_KEY);
        assertEq(string(latestClaim.dataValue), RESIDENCE);
        assertEq(latestClaim.nonce, 0);
        assertEq(keccak256(latestClaim.signature), keccak256(residenceSignature));
        assertEq(erc725Y.dataKeyControllers(RESIDENCE_DATA_KEY), wallet);
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
