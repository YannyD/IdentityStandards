// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

// solhint-disable-next-line import-path-check
import { Test } from "forge-std/src/Test.sol";

import { ClaimIssuer } from "../src/ClaimIssuer.sol";
import {
    ERC725V1Identity,
    ERC725V1Identity_InvalidClaimSignature,
    ERC725V1Identity_NotOwner
} from "../src/ERC725V1Identity.sol";
import { IdentityRegistry } from "./contracts/IdentityRegistry.sol";

contract ERC725V1IdentityTest is Test {
    uint256 internal constant INVESTOR_ACCREDITATION_TOPIC = 1;
    uint256 internal constant RESIDENCE_TOPIC = 2;
    string internal constant RESIDENCE = "Texas";

    ERC725V1Identity internal investorIdentity;
    ClaimIssuer internal accreditationIssuer;
    IdentityRegistry internal identityRegistry;

    address internal wallet;
    uint256 internal walletPrivateKey;
    address internal accreditationIssuerOwner;
    address internal accreditationClaimSigner;
    uint256 internal accreditationClaimSignerPrivateKey;
    address internal thirdPartyReader;
    bytes internal accreditationSignature;
    bytes internal residenceSignature;

    function setUp() public virtual {
        (wallet, walletPrivateKey) = makeAddrAndKey("wallet");
        accreditationIssuerOwner = makeAddr("accreditationIssuerOwner");
        (accreditationClaimSigner, accreditationClaimSignerPrivateKey) = makeAddrAndKey("accreditationClaimSigner");
        thirdPartyReader = makeAddr("thirdPartyReader");

        investorIdentity = new ERC725V1Identity(wallet);
        accreditationIssuer = new ClaimIssuer(accreditationIssuerOwner, accreditationClaimSigner);

        identityRegistry = new IdentityRegistry();
        identityRegistry.registerIdentity(wallet, investorIdentity, 840);
        identityRegistry.addClaimTopic(INVESTOR_ACCREDITATION_TOPIC);
        identityRegistry.addTrustedIssuer(accreditationIssuer, _singleTopicArray(INVESTOR_ACCREDITATION_TOPIC));

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

    function test_SetUpDeploysIdentityTiedToWalletOwner() external view {
        assertEq(investorIdentity.owner(), wallet);
        assertTrue(investorIdentity.isClaimSigner(wallet));
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
        assertTrue(accreditationIssuer.isClaimSigner(recoveredSigner));
        assertTrue(abi.decode(claim.data, (bool)));
    }

    function test_IsVerifiedAcceptsTrustedAccreditationIssuer() external view {
        assertTrue(identityRegistry.isVerified(wallet));
    }

    function test_IsVerifiedRejectsUnregisteredWallet() external {
        assertFalse(identityRegistry.isVerified(makeAddr("unregisteredWallet")));
    }

    function test_UntrustedIssuerClaimDoesNotAccreditIdentity() external {
        address untrustedWallet = makeAddr("untrustedWallet");
        (address untrustedSigner, uint256 untrustedSignerPrivateKey) = makeAddrAndKey("untrustedSigner");
        ClaimIssuer untrustedIssuer = new ClaimIssuer(makeAddr("untrustedIssuerOwner"), untrustedSigner);
        ERC725V1Identity untrustedIdentity = new ERC725V1Identity(untrustedWallet);
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

        identityRegistry.registerIdentity(untrustedWallet, untrustedIdentity, 840);

        assertFalse(identityRegistry.isVerified(untrustedWallet));
    }

    function test_AddClaimRejectsTamperedData() external {
        bytes memory signedAccreditationStatus = abi.encode(true);
        bytes memory tamperedAccreditationStatus = abi.encode(false);
        bytes memory signature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            signedAccreditationStatus
        );
        uint256 scheme = investorIdentity.SCHEME_ECDSA();

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
        assertFalse(identityRegistry.isVerified(wallet));
    }

    function test_ClaimIssuerOwnerCanRotateClaimSigner() external {
        (address replacementSigner, uint256 replacementSignerPrivateKey) = makeAddrAndKey("replacementSigner");

        vm.prank(accreditationIssuerOwner);
        accreditationIssuer.addClaimSigner(replacementSigner);

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
            investorIdentity.SCHEME_ECDSA(),
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

    function test_RemovedClaimSignerCanNoLongerSignClaims() external {
        bytes memory updatedAccreditationStatus = abi.encode(false);
        bytes memory signature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            updatedAccreditationStatus
        );
        uint256 scheme = investorIdentity.SCHEME_ECDSA();

        vm.prank(accreditationIssuerOwner);
        accreditationIssuer.removeClaimSigner(accreditationClaimSigner);

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

    function test_NonOwnerCannotAddClaimSigner() external {
        address newSigner = makeAddr("newSigner");

        vm.prank(thirdPartyReader);
        vm.expectRevert(abi.encodeWithSelector(ERC725V1Identity_NotOwner.selector, thirdPartyReader));
        accreditationIssuer.addClaimSigner(newSigner);
    }

    function test_OwnerCanRemoveClaim() external {
        bytes32 claimId = investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC);

        vm.prank(wallet);
        investorIdentity.removeClaim(claimId);

        assertEq(investorIdentity.getClaimIdsByTopic(INVESTOR_ACCREDITATION_TOPIC).length, 0);
        assertEq(investorIdentity.getClaim(claimId).issuer, address(0));
        assertFalse(identityRegistry.isVerified(wallet));
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

    function _singleTopicArray(uint256 topic) internal pure returns (uint256[] memory topics) {
        topics = new uint256[](1);
        topics[0] = topic;
    }
}
