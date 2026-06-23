// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

// solhint-disable-next-line import-path-check
import { Test } from "forge-std/src/Test.sol";

import { ClaimIssuer } from "../src/ClaimIssuer.sol";
import { ERC725V1Identity } from "../src/ERC725V1Identity.sol";
import { ERC3643ClaimTopicsRegistry } from "../src/erc3643/ERC3643ClaimTopicsRegistry.sol";
import { ERC3643IdentityRegistry } from "../src/erc3643/ERC3643IdentityRegistry.sol";
import { ERC3643LocationComplianceModule } from "../src/erc3643/ERC3643LocationComplianceModule.sol";
import {
    IERC3643Compliance,
    ERC3643PermissionedToken,
    ERC3643PermissionedToken_TransferNotCompliant
} from "../src/erc3643/ERC3643PermissionedToken.sol";
import { ERC3643TrustedIssuersRegistry } from "../src/erc3643/ERC3643TrustedIssuersRegistry.sol";

contract ERC3643PermissionedTokenTest is Test {
    // The token layer requires identity verification plus token-specific location compliance.
    uint256 internal constant INVESTOR_ACCREDITATION_TOPIC = 1;
    uint256 internal constant GEOGRAPHIC_LOCATION_TOPIC = 2;
    string internal constant TEXAS = "Texas";
    string internal constant CALIFORNIA = "California";
    string internal constant NEW_YORK = "New York";
    uint256 internal constant INITIAL_BALANCE = 1000 ether;
    uint256 internal constant SALE_AMOUNT = 100 ether;

    ERC3643ClaimTopicsRegistry internal claimTopicsRegistry;
    ERC3643TrustedIssuersRegistry internal trustedIssuersRegistry;
    ERC3643IdentityRegistry internal identityRegistry;
    ERC3643LocationComplianceModule internal locationCompliance;
    ERC3643PermissionedToken internal token;

    ClaimIssuer internal accreditationIssuer;
    ClaimIssuer internal geographicLocationIssuer;

    address internal bob;
    address internal geographicLocationIssuerOwner;
    address internal accreditationClaimSigner;
    uint256 internal accreditationClaimSignerPrivateKey;
    address internal geographicLocationClaimSigner;
    uint256 internal geographicLocationClaimSignerPrivateKey;
    address internal sam;
    address internal ivan;
    address internal claire;
    address internal nora;

    function setUp() public {
        // Bob controls the accreditation issuer; a separate issuer controls geographic location attestations.
        bob = makeAddr("bob");
        geographicLocationIssuerOwner = makeAddr("geographicLocationIssuerOwner");
        (accreditationClaimSigner, accreditationClaimSignerPrivateKey) = makeAddrAndKey("accreditationClaimSigner");
        (geographicLocationClaimSigner, geographicLocationClaimSignerPrivateKey) =
            makeAddrAndKey("geographicLocationClaimSigner");
        sam = makeAddr("sam");
        ivan = makeAddr("ivan");
        claire = makeAddr("claire");
        nora = makeAddr("nora");

        accreditationIssuer = new ClaimIssuer(bob, accreditationClaimSigner);
        geographicLocationIssuer = new ClaimIssuer(geographicLocationIssuerOwner, geographicLocationClaimSigner);

        // ERC-3643 is modeled as registries plus compliance around the ERC-735 claim identity layer.
        claimTopicsRegistry = new ERC3643ClaimTopicsRegistry();
        trustedIssuersRegistry = new ERC3643TrustedIssuersRegistry();
        identityRegistry = new ERC3643IdentityRegistry(claimTopicsRegistry, trustedIssuersRegistry);
        locationCompliance =
            new ERC3643LocationComplianceModule(identityRegistry, trustedIssuersRegistry, GEOGRAPHIC_LOCATION_TOPIC);
        token = new ERC3643PermissionedToken(
            "Permissioned Shares", "PSH", identityRegistry, IERC3643Compliance(address(locationCompliance))
        );

        claimTopicsRegistry.addClaimTopic(INVESTOR_ACCREDITATION_TOPIC);
        claimTopicsRegistry.addClaimTopic(GEOGRAPHIC_LOCATION_TOPIC);
        trustedIssuersRegistry.addTrustedIssuer(accreditationIssuer, _singleTopicArray(INVESTOR_ACCREDITATION_TOPIC));
        trustedIssuersRegistry.addTrustedIssuer(geographicLocationIssuer, _singleTopicArray(GEOGRAPHIC_LOCATION_TOPIC));
        // Geography is token-specific policy, so allowed locations live in the compliance module.
        locationCompliance.addAllowedLocation(bytes(TEXAS));
        locationCompliance.addAllowedLocation(bytes(CALIFORNIA));

        ERC725V1Identity samIdentity = _registerVerifiedIdentity(sam, TEXAS);
        ERC725V1Identity ivanIdentity = _registerVerifiedIdentity(ivan, TEXAS);

        assertTrue(identityRegistry.isVerified(sam));
        assertTrue(identityRegistry.isVerified(ivan));
        assertEq(address(identityRegistry.identity(sam)), address(samIdentity));
        assertEq(address(identityRegistry.identity(ivan)), address(ivanIdentity));

        token.mint(sam, INITIAL_BALANCE);
    }

    function test_TransferSucceedsWhenRecipientHasRequiredClaimsAndAllowedLocation() external {
        // Ivan is verified and located in Texas, so Sam can transfer the permissioned token to him.
        vm.prank(sam);
        token.transfer(ivan, SALE_AMOUNT);

        assertEq(token.balanceOf(sam), INITIAL_BALANCE - SALE_AMOUNT);
        assertEq(token.balanceOf(ivan), SALE_AMOUNT);
    }

    function test_TransferSucceedsWhenRecipientLocationIsCalifornia() external {
        // California is also allowed by the compliance module, so this recipient can receive the token.
        _registerVerifiedIdentity(claire, CALIFORNIA);

        assertTrue(identityRegistry.isVerified(claire));
        assertTrue(token.canTransfer(sam, claire, SALE_AMOUNT));

        vm.prank(sam);
        token.transfer(claire, SALE_AMOUNT);

        assertEq(token.balanceOf(claire), SALE_AMOUNT);
    }

    function test_TransferRejectsUnregisteredRecipient() external {
        // No registered identity means the token cannot even reach a successful compliance check.
        vm.prank(sam);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3643PermissionedToken_TransferNotCompliant.selector, sam, nora, SALE_AMOUNT)
        );
        token.transfer(nora, SALE_AMOUNT);
    }

    function test_TransferRejectsRecipientMissingGeographicLocationClaim() external {
        // Accreditation alone is not enough because the identity registry requires every configured topic.
        ERC725V1Identity missingLocationIdentity = new ERC725V1Identity(nora);
        _addAccreditationClaim(missingLocationIdentity);
        identityRegistry.registerIdentity(nora, missingLocationIdentity);

        assertFalse(identityRegistry.isVerified(nora));

        vm.prank(sam);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3643PermissionedToken_TransferNotCompliant.selector, sam, nora, SALE_AMOUNT)
        );
        token.transfer(nora, SALE_AMOUNT);
    }

    function test_TransferRejectsRecipientWithLocationOutsideComplianceModule() external {
        // Nora is identity-verified, but New York is rejected by this token's location module.
        _registerVerifiedIdentity(nora, NEW_YORK);

        assertTrue(identityRegistry.isVerified(nora));
        assertFalse(token.canTransfer(sam, nora, SALE_AMOUNT));

        vm.prank(sam);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3643PermissionedToken_TransferNotCompliant.selector, sam, nora, SALE_AMOUNT)
        );
        token.transfer(nora, SALE_AMOUNT);
    }

    function test_MintRejectsRecipientOutsideComplianceModule() external {
        // Minting is treated like a transfer from address(0), so recipient compliance still applies.
        _registerVerifiedIdentity(nora, NEW_YORK);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643PermissionedToken_TransferNotCompliant.selector, address(0), nora, SALE_AMOUNT
            )
        );
        token.mint(nora, SALE_AMOUNT);
    }

    function _registerVerifiedIdentity(
        address wallet,
        string memory location
    )
        internal
        returns (ERC725V1Identity identity)
    {
        // Each registered test identity gets both required claims before entering the identity registry.
        identity = new ERC725V1Identity(wallet);

        _addAccreditationClaim(identity);
        _addGeographicLocationClaim(identity, location);
        identityRegistry.registerIdentity(wallet, identity);
    }

    function _addAccreditationClaim(ERC725V1Identity identity) internal {
        bytes memory accreditationStatus = abi.encode(true);
        bytes memory signature = _signClaim(
            accreditationIssuer,
            accreditationClaimSignerPrivateKey,
            identity,
            INVESTOR_ACCREDITATION_TOPIC,
            accreditationStatus
        );

        vm.prank(accreditationClaimSigner);
        identity.addClaim(
            INVESTOR_ACCREDITATION_TOPIC,
            identity.SCHEME_ECDSA(),
            address(accreditationIssuer),
            signature,
            accreditationStatus,
            ""
        );
    }

    function _addGeographicLocationClaim(ERC725V1Identity identity, string memory location) internal {
        bytes memory locationData = bytes(location);
        bytes memory signature = _signClaim(
            geographicLocationIssuer,
            geographicLocationClaimSignerPrivateKey,
            identity,
            GEOGRAPHIC_LOCATION_TOPIC,
            locationData
        );

        vm.prank(geographicLocationClaimSigner);
        identity.addClaim(
            GEOGRAPHIC_LOCATION_TOPIC,
            identity.SCHEME_ECDSA(),
            address(geographicLocationIssuer),
            signature,
            locationData,
            ""
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
