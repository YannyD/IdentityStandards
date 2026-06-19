// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

// solhint-disable-next-line import-path-check
import { Test } from "forge-std/src/Test.sol";

import { ClaimIssuer } from "../src/ClaimIssuer.sol";
import {
    ERC725V1Identity,
    ERC725V1Identity_ClaimDoesNotExist,
    ERC725V1Identity_InvalidClaimSignature,
    ERC725V1Identity_KeyDoesNotExist,
    ERC725V1Identity_NotManagementKey
} from "../src/ERC725V1Identity.sol";
import { AccreditationVerifier } from "./contracts/AccreditationVerifier.sol";

contract ERC725V1IdentityTest is Test {
    uint256 internal constant INVESTOR_ACCREDITATION_TOPIC = 1;
    uint256 internal constant RESIDENCE_TOPIC = 2;
    string internal constant RESIDENCE = "Texas";

    ERC725V1Identity internal investorIdentity;
    ClaimIssuer internal accreditationIssuer;
    AccreditationVerifier internal accreditationVerifier;

    address internal wallet;
    uint256 internal walletPrivateKey;
    address internal accreditationIssuerManager;
    address internal accreditationClaimSigner;
    uint256 internal accreditationClaimSignerPrivateKey;
    address internal thirdPartyReader;
    bytes internal accreditationSignature;
    bytes internal residenceSignature;

    function setUp() public virtual {
        (wallet, walletPrivateKey) = makeAddrAndKey("wallet");
        accreditationIssuerManager = makeAddr("accreditationIssuerManager");
        (accreditationClaimSigner, accreditationClaimSignerPrivateKey) = makeAddrAndKey("accreditationClaimSigner");
        thirdPartyReader = makeAddr("thirdPartyReader");

        investorIdentity = new ERC725V1Identity(wallet);
        accreditationIssuer = new ClaimIssuer(accreditationIssuerManager, accreditationClaimSigner);

        accreditationVerifier = new AccreditationVerifier();
        accreditationVerifier.setTrustedIssuer(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC, true);

        bytes memory accreditationStatus = abi.encode(true);
        accreditationSignature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            accreditationStatus
        );

        vm.prank(accreditationClaimSigner);
        investorIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            investorIdentity.SCHEME_ECDSA(),
            address(accreditationIssuer),
            accreditationSignature,
            accreditationStatus,
            ""
        );

        bytes memory residence = bytes(RESIDENCE);
        residenceSignature =
            _signClaim(investorIdentity, walletPrivateKey, investorIdentity, RESIDENCE_TOPIC, residence);

        vm.prank(wallet);
        investorIdentity.addClaim(
            RESIDENCE_TOPIC,
            investorIdentity.SCHEME_ECDSA(),
            address(investorIdentity),
            residenceSignature,
            residence,
            ""
        );
    }

    function test_SetUpDeploysIdentityTiedToWalletManagementKey() external view {
        assertTrue(
            investorIdentity.keyHasPurpose(investorIdentity.addressToKey(wallet), investorIdentity.MANAGEMENT_KEY())
        );
    }

    function test_SetUpStoresInvestorAccreditationClaim() external view {
        bytes32 claimId = investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC);
        ERC725V1Identity.Claim memory claim = investorIdentity.getClaim(claimId);
        bytes32[] memory topicClaimIds = investorIdentity.getClaimIdsByTopic(INVESTOR_ACCREDITATION_TOPIC);

        assertEq(topicClaimIds.length, 1);
        assertEq(topicClaimIds[0], claimId);
        assertEq(claim.topic, INVESTOR_ACCREDITATION_TOPIC);
        assertEq(claim.scheme, investorIdentity.SCHEME_ECDSA());
        assertEq(claim.issuer, address(accreditationIssuer));
        assertTrue(abi.decode(claim.data, (bool)));
        assertEq(keccak256(claim.signature), keccak256(accreditationSignature));
        assertTrue(
            accreditationIssuer.isClaimValid(
                address(investorIdentity), INVESTOR_ACCREDITATION_TOPIC, claim.signature, claim.data
            )
        );
    }

    function test_ThirdPartyReadsAccreditationIssuerAndSigner() external {
        bytes32 claimId = investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC);

        vm.prank(thirdPartyReader);
        ERC725V1Identity.Claim memory claim = investorIdentity.getClaim(claimId);

        address recoveredSigner = accreditationIssuer.recoverClaimSigner(
            address(investorIdentity), INVESTOR_ACCREDITATION_TOPIC, claim.signature, claim.data
        );

        assertEq(claim.issuer, address(accreditationIssuer));
        assertEq(recoveredSigner, accreditationClaimSigner);
        assertTrue(
            accreditationIssuer.keyHasPurpose(
                accreditationIssuer.addressToKey(recoveredSigner), accreditationIssuer.CLAIM_SIGNER_KEY()
            )
        );
        assertTrue(abi.decode(claim.data, (bool)));
    }

    function test_VerifierAcceptsTrustedAccreditationIssuer() external view {
        assertTrue(accreditationVerifier.isAccredited(investorIdentity, INVESTOR_ACCREDITATION_TOPIC));
    }

    function test_UntrustedIssuerClaimDoesNotAccreditIdentity() external {
        (address untrustedSigner, uint256 untrustedSignerPrivateKey) = makeAddrAndKey("untrustedSigner");
        ClaimIssuer untrustedIssuer = new ClaimIssuer(makeAddr("untrustedIssuerManager"), untrustedSigner);
        ERC725V1Identity untrustedIdentity = new ERC725V1Identity(wallet);
        bytes memory accreditationStatus = abi.encode(true);
        bytes memory signature = _signClaim(
            untrustedIssuer,
            untrustedSignerPrivateKey,
            untrustedIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            accreditationStatus
        );

        vm.prank(untrustedSigner);
        untrustedIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            untrustedIdentity.SCHEME_ECDSA(),
            address(untrustedIssuer),
            signature,
            accreditationStatus,
            ""
        );

        assertFalse(accreditationVerifier.isAccredited(untrustedIdentity, INVESTOR_ACCREDITATION_TOPIC));
    }

    function test_AddClaimRejectsInvalidIssuerSignature() external {
        bytes memory signedAccreditationStatus = abi.encode(true);
        bytes memory tamperedAccreditationStatus = abi.encode(false);
        uint256 scheme = investorIdentity.SCHEME_ECDSA();
        bytes memory signature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            signedAccreditationStatus
        );

        vm.prank(accreditationClaimSigner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC725V1Identity_InvalidClaimSignature.selector,
                address(accreditationIssuer),
                INVESTOR_ACCREDITATION_TOPIC
            )
        );
        investorIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            scheme,
            address(accreditationIssuer),
            signature,
            tamperedAccreditationStatus,
            ""
        );
    }

    function test_UpdatedAccreditationClaimSupersedesOldClaim() external {
        bytes32 claimId = investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC);
        bytes32 oldClaimDataHash = keccak256(investorIdentity.getClaim(claimId).data);
        bytes memory updatedAccreditationStatus = abi.encode(false);
        bytes memory updatedSignature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            updatedAccreditationStatus
        );

        vm.prank(accreditationClaimSigner);
        bytes32 updatedClaimId = investorIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            investorIdentity.SCHEME_ECDSA(),
            address(accreditationIssuer),
            updatedSignature,
            updatedAccreditationStatus,
            ""
        );

        ERC725V1Identity.Claim memory latestClaim = investorIdentity.getClaim(claimId);

        assertEq(updatedClaimId, claimId);
        assertNotEq(keccak256(latestClaim.data), oldClaimDataHash);
        assertFalse(abi.decode(latestClaim.data, (bool)));
        assertFalse(accreditationVerifier.isAccredited(investorIdentity, INVESTOR_ACCREDITATION_TOPIC));
    }

    function test_ClaimIssuerCanRotateClaimSignerKey() external {
        (address replacementSigner, uint256 replacementSignerPrivateKey) = makeAddrAndKey("replacementSigner");
        bytes32 replacementSignerKey = accreditationIssuer.addressToKey(replacementSigner);
        uint256 claimSignerPurpose = accreditationIssuer.CLAIM_SIGNER_KEY();
        uint256 keyType = accreditationIssuer.KEY_TYPE_ECDSA();
        uint256 scheme = investorIdentity.SCHEME_ECDSA();

        vm.prank(accreditationIssuerManager);
        accreditationIssuer.addKey(replacementSignerKey, claimSignerPurpose, keyType);

        bytes memory updatedAccreditationStatus = abi.encode(false);
        bytes memory replacementSignature = _signClaim(
            accreditationIssuer,
            replacementSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            updatedAccreditationStatus
        );

        vm.prank(replacementSigner);
        investorIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            scheme,
            address(accreditationIssuer),
            replacementSignature,
            updatedAccreditationStatus,
            ""
        );

        ERC725V1Identity.Claim memory latestClaim = investorIdentity.getClaim(
            investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC)
        );

        assertEq(
            accreditationIssuer.recoverClaimSigner(
                address(investorIdentity), INVESTOR_ACCREDITATION_TOPIC, latestClaim.signature, latestClaim.data
            ),
            replacementSigner
        );
        assertFalse(abi.decode(latestClaim.data, (bool)));
    }

    function test_RemovedClaimSignerKeyCanNoLongerSignClaims() external {
        bytes32 signerKey = accreditationIssuer.addressToKey(accreditationClaimSigner);
        uint256 claimSignerPurpose = accreditationIssuer.CLAIM_SIGNER_KEY();
        uint256 scheme = investorIdentity.SCHEME_ECDSA();

        vm.prank(accreditationIssuerManager);
        accreditationIssuer.removeKey(signerKey, claimSignerPurpose);

        bytes memory updatedAccreditationStatus = abi.encode(false);
        bytes memory signature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            updatedAccreditationStatus
        );

        vm.prank(accreditationClaimSigner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC725V1Identity_InvalidClaimSignature.selector,
                address(accreditationIssuer),
                INVESTOR_ACCREDITATION_TOPIC
            )
        );
        investorIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            scheme,
            address(accreditationIssuer),
            signature,
            updatedAccreditationStatus,
            ""
        );
    }

    function test_NonManagementCannotAddClaimSignerKey() external {
        bytes32 newSignerKey = accreditationIssuer.addressToKey(makeAddr("newSigner"));
        uint256 claimSignerPurpose = accreditationIssuer.CLAIM_SIGNER_KEY();
        uint256 keyType = accreditationIssuer.KEY_TYPE_ECDSA();

        vm.prank(thirdPartyReader);
        vm.expectRevert(abi.encodeWithSelector(ERC725V1Identity_NotManagementKey.selector, thirdPartyReader));
        accreditationIssuer.addKey(newSignerKey, claimSignerPurpose, keyType);
    }

    function test_ManagementCanRemoveClaim() external {
        bytes32 claimId = investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC);

        vm.prank(wallet);
        investorIdentity.removeClaim(claimId);

        assertEq(investorIdentity.getClaimIdsByTopic(INVESTOR_ACCREDITATION_TOPIC).length, 0);
        assertEq(investorIdentity.getClaim(claimId).issuer, address(0));
        assertFalse(accreditationVerifier.isAccredited(investorIdentity, INVESTOR_ACCREDITATION_TOPIC));
    }

    function test_RemoveClaimRejectsMissingClaim() external {
        bytes32 missingClaimId = keccak256("missingClaim");

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC725V1Identity_ClaimDoesNotExist.selector, missingClaimId));
        investorIdentity.removeClaim(missingClaimId);
    }

    function test_NonManagementCannotRemoveClaim() external {
        bytes32 claimId = investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC);

        vm.prank(thirdPartyReader);
        vm.expectRevert(abi.encodeWithSelector(ERC725V1Identity_NotManagementKey.selector, thirdPartyReader));
        investorIdentity.removeClaim(claimId);
    }

    function test_SetUpStoresWalletResidenceSelfClaim() external view {
        bytes32 claimId = investorIdentity.getClaimId(address(investorIdentity), RESIDENCE_TOPIC);
        ERC725V1Identity.Claim memory claim = investorIdentity.getClaim(claimId);

        assertEq(claim.topic, RESIDENCE_TOPIC);
        assertEq(claim.issuer, address(investorIdentity));
        assertEq(string(claim.data), RESIDENCE);
        assertEq(keccak256(claim.signature), keccak256(residenceSignature));
        assertTrue(
            investorIdentity.isClaimValid(address(investorIdentity), RESIDENCE_TOPIC, claim.signature, claim.data)
        );
    }

    function test_RemoveKeyRejectsMissingPurpose() external {
        bytes32 signerKey = accreditationIssuer.addressToKey(accreditationClaimSigner);
        uint256 actionPurpose = accreditationIssuer.ACTION_KEY();

        vm.prank(accreditationIssuerManager);
        vm.expectRevert(abi.encodeWithSelector(ERC725V1Identity_KeyDoesNotExist.selector, signerKey, actionPurpose));
        accreditationIssuer.removeKey(signerKey, actionPurpose);
    }

    function _signClaim(
        ERC725V1Identity issuer,
        uint256 signerPrivateKey,
        ERC725V1Identity identity,
        uint256 topic,
        bytes memory data
    )
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest = issuer.getClaimDigest(address(identity), topic, data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }
}
