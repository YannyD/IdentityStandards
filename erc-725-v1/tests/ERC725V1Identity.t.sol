// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

// solhint-disable-next-line import-path-check
import {Test} from "forge-std/src/Test.sol";

import {ClaimIssuer} from "../src/ClaimIssuer.sol";
import {
    ERC725V1Identity,
    ERC725V1Identity_InvalidClaimSignature,
    ERC725V1Identity_NotOwner
} from "../src/ERC725V1Identity.sol";
import {SimplifiedIdentityClaimRegistry} from "./contracts/SimplifiedIdentityClaimRegistry.sol";

contract ERC725V1IdentityTest is Test {
    // The simplified registry requires both topics before a wallet is considered verified.
    uint256 internal constant INVESTOR_ACCREDITATION_TOPIC = 1;
    uint256 internal constant GEOGRAPHIC_LOCATION_TOPIC = 2;
    string internal constant GEOGRAPHIC_LOCATION = "Texas";
    string internal constant ALTERNATE_GEOGRAPHIC_LOCATION = "California";

    ERC725V1Identity internal investorIdentity;
    ClaimIssuer internal accreditationIssuer;
    ClaimIssuer internal geographicLocationIssuer;
    SimplifiedIdentityClaimRegistry internal simplifiedClaimRegistry;

    address internal wallet;
    uint256 internal walletPrivateKey;
    address internal accreditationIssuerOwner;
    address internal accreditationClaimSigner;
    uint256 internal accreditationClaimSignerPrivateKey;
    address internal geographicLocationIssuerOwner;
    address internal geographicLocationClaimSigner;
    uint256 internal geographicLocationClaimSignerPrivateKey;
    address internal thirdPartyReader;
    bytes internal accreditationSignature;
    bytes internal geographicLocationSignature;

    /// @notice Initializes test actors, contracts, registry policy, and baseline claims.
    function setUp() public virtual {
        _setupActors();
        _deployContracts();

        (bytes memory accreditationStatus, bytes memory geographicLocation) = _configureRegistry();

        _addAccreditationClaim(accreditationStatus);
        _addGeographicLocationClaim(geographicLocation);
    }

    /// @notice Creates deterministic test addresses and private keys for actors in this suite.
    function _setupActors() internal {
        // Ivan owns the subject identity; separate issuer identities sign claims about accreditation and location.
        (wallet, walletPrivateKey) = makeAddrAndKey("wallet");
        accreditationIssuerOwner = makeAddr("accreditationIssuerOwner");
        (accreditationClaimSigner, accreditationClaimSignerPrivateKey) = makeAddrAndKey("accreditationClaimSigner");
        geographicLocationIssuerOwner = makeAddr("geographicLocationIssuerOwner");
        (geographicLocationClaimSigner, geographicLocationClaimSignerPrivateKey) = makeAddrAndKey(
            "geographicLocationClaimSigner"
        );
        thirdPartyReader = makeAddr("thirdPartyReader");
    }

    /// @notice Deploys identity, issuers, and registry contracts, then links the wallet to its identity.
    function _deployContracts() internal {
        investorIdentity = new ERC725V1Identity(wallet);
        accreditationIssuer = new ClaimIssuer(accreditationIssuerOwner, accreditationClaimSigner);
        geographicLocationIssuer = new ClaimIssuer(geographicLocationIssuerOwner, geographicLocationClaimSigner);

        simplifiedClaimRegistry = new SimplifiedIdentityClaimRegistry();
        simplifiedClaimRegistry.registerIdentity(wallet, investorIdentity);
    }

    /// @notice Configures required claim topics, allowed claim data, and trusted issuers in the registry.
    /// @return accreditationStatus Encoded boolean accreditation status allowed by policy.
    /// @return geographicLocation Encoded primary geographic location allowed by policy.
    function _configureRegistry() internal returns (bytes memory accreditationStatus, bytes memory geographicLocation) {
        // The registry models the relying party's policy: required topics, allowed data, and trusted issuers.
        accreditationStatus = abi.encode(true);
        geographicLocation = bytes(GEOGRAPHIC_LOCATION);

        simplifiedClaimRegistry.addClaimTopic(INVESTOR_ACCREDITATION_TOPIC);
        simplifiedClaimRegistry.addClaimTopic(GEOGRAPHIC_LOCATION_TOPIC);
        simplifiedClaimRegistry.addAllowedClaimData(INVESTOR_ACCREDITATION_TOPIC, accreditationStatus);
        simplifiedClaimRegistry.addAllowedClaimData(GEOGRAPHIC_LOCATION_TOPIC, geographicLocation);
        simplifiedClaimRegistry.addAllowedClaimData(GEOGRAPHIC_LOCATION_TOPIC, bytes(ALTERNATE_GEOGRAPHIC_LOCATION));
        simplifiedClaimRegistry.addTrustedIssuer(accreditationIssuer, _singleTopicArray(INVESTOR_ACCREDITATION_TOPIC));
        simplifiedClaimRegistry.addTrustedIssuer(
            geographicLocationIssuer,
            _singleTopicArray(GEOGRAPHIC_LOCATION_TOPIC)
        );
    }

    /// @notice Signs and stores the investor accreditation claim on the identity.
    /// @param accreditationStatus Encoded accreditation payload used for signing and claim storage.
    function _addAccreditationClaim(bytes memory accreditationStatus) internal {
        accreditationSignature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            investorIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            accreditationStatus
        );

        // Bob's approved claim signer posts the accreditation claim onto Ivan's identity.
        vm.prank(accreditationClaimSigner);
        investorIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            investorIdentity.SCHEME_ECDSA(),
            address(accreditationIssuer),
            accreditationSignature,
            accreditationStatus,
            ""
        );
    }

    /// @notice Signs and stores the investor geographic location claim on the identity.
    /// @param geographicLocation Encoded location payload used for signing and claim storage.
    function _addGeographicLocationClaim(bytes memory geographicLocation) internal {
        geographicLocationSignature = _signClaim(
            geographicLocationIssuer,
            geographicLocationClaimSignerPrivateKey,
            investorIdentity,
            GEOGRAPHIC_LOCATION_TOPIC,
            geographicLocation
        );

        // A separate trusted issuer posts the location claim; the registry later decides whether the location is
        // allowed.
        vm.prank(geographicLocationClaimSigner);
        investorIdentity.addClaim(
            GEOGRAPHIC_LOCATION_TOPIC,
            investorIdentity.SCHEME_ECDSA(),
            address(geographicLocationIssuer),
            geographicLocationSignature,
            geographicLocation,
            ""
        );
    }

    function test_SetUpDeploysIdentityTiedToWalletOwner() external view {
        assertEq(investorIdentity.owner(), wallet);
        assertTrue(investorIdentity.isClaimSigner(wallet));
    }

    function test_SetUpStoresInvestorAccreditationClaim() external view {
        // The stored claim keeps the ERC-735 shape and can be validated by the issuer that created it.
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
                address(investorIdentity),
                INVESTOR_ACCREDITATION_TOPIC,
                claim.signature,
                claim.data
            )
        );
    }

    function test_ThirdPartyReadsAccreditationIssuerAndSigner() external {
        // Sam can inspect the claim, recover the signer, and see that the issuer authorized that signer.
        bytes32 claimId = investorIdentity.getClaimId(address(accreditationIssuer), INVESTOR_ACCREDITATION_TOPIC);

        vm.prank(thirdPartyReader);
        ERC725V1Identity.Claim memory claim = investorIdentity.getClaim(claimId);

        address recoveredSigner = accreditationIssuer.recoverClaimSigner(
            address(investorIdentity),
            INVESTOR_ACCREDITATION_TOPIC,
            claim.signature,
            claim.data
        );

        assertEq(claim.issuer, address(accreditationIssuer));
        assertEq(recoveredSigner, accreditationClaimSigner);
        assertTrue(accreditationIssuer.isClaimSigner(recoveredSigner));
        assertTrue(abi.decode(claim.data, (bool)));
    }

    function test_IsVerifiedAcceptsTrustedAccreditationAndLocationClaims() external view {
        assertTrue(simplifiedClaimRegistry.isVerified(wallet));
    }

    function test_IsVerifiedRejectsUnregisteredWallet() external {
        assertFalse(simplifiedClaimRegistry.isVerified(makeAddr("unregisteredWallet")));
    }

    function test_UntrustedIssuerClaimsDoNotVerifyIdentity() external {
        // Even valid signatures fail verification if the issuer is not trusted for the required topics.
        address untrustedWallet = makeAddr("untrustedWallet");
        (address untrustedSigner, uint256 untrustedSignerPrivateKey) = makeAddrAndKey("untrustedSigner");
        ClaimIssuer untrustedIssuer = new ClaimIssuer(makeAddr("untrustedIssuerOwner"), untrustedSigner);
        ERC725V1Identity untrustedIdentity = new ERC725V1Identity(untrustedWallet);
        bytes memory accreditationStatus = abi.encode(true);
        bytes memory geographicLocation = bytes(GEOGRAPHIC_LOCATION);
        bytes memory untrustedAccreditationSignature = _signClaim(
            untrustedIssuer,
            untrustedSignerPrivateKey,
            untrustedIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            accreditationStatus
        );
        bytes memory untrustedGeographicLocationSignature = _signClaim(
            untrustedIssuer,
            untrustedSignerPrivateKey,
            untrustedIdentity,
            GEOGRAPHIC_LOCATION_TOPIC,
            geographicLocation
        );

        vm.prank(untrustedSigner);
        untrustedIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            untrustedIdentity.SCHEME_ECDSA(),
            address(untrustedIssuer),
            untrustedAccreditationSignature,
            accreditationStatus,
            ""
        );

        vm.prank(untrustedSigner);
        untrustedIdentity.addClaim(
            GEOGRAPHIC_LOCATION_TOPIC,
            untrustedIdentity.SCHEME_ECDSA(),
            address(untrustedIssuer),
            untrustedGeographicLocationSignature,
            geographicLocation,
            ""
        );

        simplifiedClaimRegistry.registerIdentity(untrustedWallet, untrustedIdentity);

        assertFalse(simplifiedClaimRegistry.isVerified(untrustedWallet));
    }

    function test_MissingGeographicLocationClaimDoesNotVerifyIdentity() external {
        // isVerified requires every configured topic; accreditation alone is not enough.
        address partialWallet = makeAddr("partialWallet");
        ERC725V1Identity partialIdentity = new ERC725V1Identity(partialWallet);
        bytes memory accreditationStatus = abi.encode(true);
        bytes memory signature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            partialIdentity,
            INVESTOR_ACCREDITATION_TOPIC,
            accreditationStatus
        );

        vm.prank(accreditationClaimSigner);
        partialIdentity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            partialIdentity.SCHEME_ECDSA(),
            address(accreditationIssuer),
            signature,
            accreditationStatus,
            ""
        );

        simplifiedClaimRegistry.registerIdentity(partialWallet, partialIdentity);

        assertFalse(simplifiedClaimRegistry.isVerified(partialWallet));
    }

    function test_AddClaimRejectsTamperedData() external {
        // A signature over "true" accreditation cannot be reused to submit "false" data.
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
        // Claims are keyed by issuer + topic, so a later claim from the same issuer replaces the old value.
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
        assertFalse(simplifiedClaimRegistry.isVerified(wallet));
    }

    function test_UpdatedGeographicLocationClaimToAlternateAllowedLocationStillVerifies() external {
        // The registry accepts either allowed location value for the same geographic-location topic.
        bytes32 claimId = investorIdentity.getClaimId(address(geographicLocationIssuer), GEOGRAPHIC_LOCATION_TOPIC);
        bytes memory updatedGeographicLocation = bytes(ALTERNATE_GEOGRAPHIC_LOCATION);
        bytes memory updatedSignature = _signClaim(
            geographicLocationIssuer,
            geographicLocationClaimSignerPrivateKey,
            investorIdentity,
            GEOGRAPHIC_LOCATION_TOPIC,
            updatedGeographicLocation
        );

        vm.prank(geographicLocationClaimSigner);
        bytes32 updatedClaimId = investorIdentity.addClaim(
            GEOGRAPHIC_LOCATION_TOPIC,
            investorIdentity.SCHEME_ECDSA(),
            address(geographicLocationIssuer),
            updatedSignature,
            updatedGeographicLocation,
            ""
        );

        ERC725V1Identity.Claim memory latestClaim = investorIdentity.getClaim(claimId);

        assertEq(updatedClaimId, claimId);
        assertEq(string(latestClaim.data), ALTERNATE_GEOGRAPHIC_LOCATION);
        assertTrue(simplifiedClaimRegistry.isVerified(wallet));
    }

    function test_UpdatedGeographicLocationClaimOutsideAllowedLocationsRejectsVerification() external {
        // The location claim is validly signed, but its data is outside the registry's allowed set.
        bytes32 claimId = investorIdentity.getClaimId(address(geographicLocationIssuer), GEOGRAPHIC_LOCATION_TOPIC);
        bytes memory updatedGeographicLocation = bytes("New York");
        bytes memory updatedSignature = _signClaim(
            geographicLocationIssuer,
            geographicLocationClaimSignerPrivateKey,
            investorIdentity,
            GEOGRAPHIC_LOCATION_TOPIC,
            updatedGeographicLocation
        );

        vm.prank(geographicLocationClaimSigner);
        bytes32 updatedClaimId = investorIdentity.addClaim(
            GEOGRAPHIC_LOCATION_TOPIC,
            investorIdentity.SCHEME_ECDSA(),
            address(geographicLocationIssuer),
            updatedSignature,
            updatedGeographicLocation,
            ""
        );

        ERC725V1Identity.Claim memory latestClaim = investorIdentity.getClaim(claimId);

        assertEq(updatedClaimId, claimId);
        assertEq(string(latestClaim.data), "New York");
        assertFalse(simplifiedClaimRegistry.isVerified(wallet));
    }

    function test_ClaimIssuerOwnerCanRotateClaimSigner() external {
        // The issuer owner can authorize a new signing key without changing the issuer identity address.
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
                address(investorIdentity),
                INVESTOR_ACCREDITATION_TOPIC,
                latestClaim.signature,
                latestClaim.data
            ),
            replacementSigner
        );
        assertFalse(abi.decode(latestClaim.data, (bool)));
    }

    function test_RemovedClaimSignerCanNoLongerSignClaims() external {
        // Once a signer is removed from the issuer identity, new claims signed by that key are rejected.
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
        assertFalse(simplifiedClaimRegistry.isVerified(wallet));
    }

    function test_SetUpStoresGeographicLocationClaim() external view {
        // Location is represented as a normal identity claim, not as separate registry metadata.
        bytes32 claimId = investorIdentity.getClaimId(address(geographicLocationIssuer), GEOGRAPHIC_LOCATION_TOPIC);
        ERC725V1Identity.Claim memory claim = investorIdentity.getClaim(claimId);

        assertEq(claim.topic, GEOGRAPHIC_LOCATION_TOPIC);
        assertEq(claim.issuer, address(geographicLocationIssuer));
        assertEq(string(claim.data), GEOGRAPHIC_LOCATION);
        assertEq(keccak256(claim.signature), keccak256(geographicLocationSignature));
        assertTrue(
            geographicLocationIssuer.isClaimValid(
                address(investorIdentity),
                GEOGRAPHIC_LOCATION_TOPIC,
                claim.signature,
                claim.data
            )
        );
    }

    function _signClaim(
        ERC725V1Identity issuer,
        uint256 signerPrivateKey,
        ERC725V1Identity identity,
        uint256 topic,
        bytes memory data
    ) internal pure returns (bytes memory) {
        bytes32 digest = issuer.getClaimDigest(address(identity), topic, data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    function _singleTopicArray(uint256 topic) internal pure returns (uint256[] memory topics) {
        topics = new uint256[](1);
        topics[0] = topic;
    }
}
