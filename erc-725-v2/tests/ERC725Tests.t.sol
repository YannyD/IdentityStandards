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
    ERC725YSignedClaimStore_InvalidSignature,
    ERC725YSignedClaimStore_InvalidSubject
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
        (wallet, walletPrivateKey) = makeAddrAndKey("wallet");
        (accreditationIssuer, accreditationIssuerPrivateKey) = makeAddrAndKey("accreditationIssuer");
        thirdPartyReader = makeAddr("thirdPartyReader");

        vm.prank(wallet);
        erc725Y = new ERC725YSignedClaimStore();

        approvedSigners[accreditationIssuer] = true;
        accreditationVerifier = new AccreditationVerifier();
        accreditationVerifier.setApprovedSigner(accreditationIssuer, true);

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

    function test_SetUpStoresInvestorAccreditationAttestation() external view {
        bytes32 claimKey = erc725Y.getClaimKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);
        address[] memory signers = erc725Y.getClaimSignersByDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory claim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);

        assertEq(erc725Y.getData(INVESTOR_ACCREDITATION_STATUS_DATA_KEY).length, 0);
        assertGt(erc725Y.getData(claimKey).length, 0);
        assertEq(signers.length, 1);
        assertEq(signers[0], accreditationIssuer);
        assertTrue(erc725Y.hasClaimSignerForDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer));
        assertEq(claim.signer, accreditationIssuer);
        assertEq(claim.postedBy, accreditationIssuer);
        assertEq(claim.subject, wallet);
        assertEq(claim.dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(claim.dataValue, (bool)));
        assertEq(claim.nonce, 0);
        assertEq(keccak256(claim.signature), keccak256(accreditationSignature));
        assertEq(erc725Y.nonces(accreditationIssuer), 1);
    }

    function test_ThirdPartyReadsAccreditationAttestation() external {
        vm.prank(thirdPartyReader);
        ERC725YSignedClaimStore.SignedClaim memory claim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);

        assertEq(claim.signer, accreditationIssuer);
        assertEq(
            ECDSA.recover(
                erc725Y.hashSetData(claim.subject, claim.dataKey, keccak256(claim.dataValue), claim.nonce),
                claim.signature
            ),
            claim.signer
        );
        assertTrue(approvedSigners[claim.signer]);
        assertEq(claim.postedBy, accreditationIssuer);
        assertEq(claim.subject, wallet);
        assertEq(claim.dataKey, INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        assertTrue(abi.decode(claim.dataValue, (bool)));
    }

    function test_VerifierAcceptsApprovedAccreditationSigner() external view {
        assertTrue(accreditationVerifier.isAccredited(erc725Y, INVESTOR_ACCREDITATION_STATUS_DATA_KEY));
    }

    function test_UnapprovedSignerCanPostSeparateAttestationButDoesNotAccredit() external {
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
        erc725Y.setDataWithSignature(
            unapprovedIssuer, wallet, INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationStatus, unapprovedSignature
        );

        address[] memory signers = erc725Y.getClaimSignersByDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory trustedClaim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);
        ERC725YSignedClaimStore.SignedClaim memory unapprovedClaim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, unapprovedIssuer);

        assertEq(signers.length, 2);
        assertEq(trustedClaim.signer, accreditationIssuer);
        assertEq(unapprovedClaim.signer, unapprovedIssuer);
        assertTrue(abi.decode(trustedClaim.dataValue, (bool)));
        assertTrue(abi.decode(unapprovedClaim.dataValue, (bool)));

        accreditationVerifier.setApprovedSigner(accreditationIssuer, false);
        assertFalse(accreditationVerifier.isAccredited(erc725Y, INVESTOR_ACCREDITATION_STATUS_DATA_KEY));
    }

    function test_VerifierAcceptsAnyTrustedTrueAttestation() external {
        (address replacementIssuer, uint256 replacementIssuerPrivateKey) = makeAddrAndKey("replacementIssuer");

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

        accreditationVerifier.setApprovedSigner(replacementIssuer, true);

        address[] memory signers = erc725Y.getClaimSignersByDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory firstClaim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);
        ERC725YSignedClaimStore.SignedClaim memory replacementClaim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, replacementIssuer);

        assertEq(signers.length, 2);
        assertFalse(abi.decode(firstClaim.dataValue, (bool)));
        assertTrue(abi.decode(replacementClaim.dataValue, (bool)));
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

    function test_UpdatedAccreditationAttestationSupersedesSameSignerOnly() external {
        bytes32 claimKey = erc725Y.getClaimKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);
        bytes32 oldStoredClaimHash = keccak256(erc725Y.getData(claimKey));
        ERC725YSignedClaimStore.SignedClaim memory oldClaim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);

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

        address[] memory signers = erc725Y.getClaimSignersByDataKey(INVESTOR_ACCREDITATION_STATUS_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory updatedClaim =
            erc725Y.getClaim(INVESTOR_ACCREDITATION_STATUS_DATA_KEY, accreditationIssuer);

        assertTrue(abi.decode(oldClaim.dataValue, (bool)));
        assertEq(signers.length, 1);
        assertNotEq(keccak256(erc725Y.getData(claimKey)), oldStoredClaimHash);
        assertFalse(abi.decode(updatedClaim.dataValue, (bool)));
        assertEq(updatedClaim.nonce, 1);
        assertEq(erc725Y.nonces(accreditationIssuer), 2);
        assertFalse(accreditationVerifier.isAccredited(erc725Y, INVESTOR_ACCREDITATION_STATUS_DATA_KEY));
    }

    function test_SetUpStoresWalletResidenceAttestation() external view {
        bytes32 claimKey = erc725Y.getClaimKey(RESIDENCE_DATA_KEY, wallet);
        address[] memory signers = erc725Y.getClaimSignersByDataKey(RESIDENCE_DATA_KEY);
        ERC725YSignedClaimStore.SignedClaim memory claim = erc725Y.getClaim(RESIDENCE_DATA_KEY, wallet);

        assertEq(erc725Y.getData(RESIDENCE_DATA_KEY).length, 0);
        assertGt(erc725Y.getData(claimKey).length, 0);
        assertEq(signers.length, 1);
        assertEq(signers[0], wallet);
        assertEq(claim.signer, wallet);
        assertEq(claim.postedBy, wallet);
        assertEq(claim.subject, wallet);
        assertEq(claim.dataKey, RESIDENCE_DATA_KEY);
        assertEq(string(claim.dataValue), RESIDENCE);
        assertEq(claim.nonce, 0);
        assertEq(keccak256(claim.signature), keccak256(residenceSignature));
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
