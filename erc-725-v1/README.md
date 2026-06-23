# Identity Standards and Implementation: ERC-725 v1

This repo shows the older ERC-725 v1 / ERC-734 / ERC-735 / ONCHAINID identity-claim pattern used by ERC-3643-style
permissioned-token systems. It focuses only on the parts needed to compare claim issuance and verification with the
ERC-725 v2 example.

The point of this model is not that ERC-3643 is the only thing that can use these identities. ERC-3643 can be
accommodated by adding registry and token-transfer checks around the identity-claim layer, and other ERC-734/735-compliant
identity implementations can be accommodated as long as they expose the same claim holder and claim issuer verification
surface.

The v1 lineage stores claims as structured records on an identity:

- a claim has a topic, scheme, issuer, signature, data, and URI;
- a trusted issuer contract validates whether the signature came from one of its approved claim signers;
- a simplified identity-claim registry model records which wallet owns which identity, which claim topics are required,
  which claim data is expected, and which issuers are trusted for each topic;
- `isVerified(wallet)` reads the wallet's identity, checks the required topics, calls `isClaimValid`, then decodes the
  claim data.

## Claim Issuers

`ClaimIssuer` is an `ERC725V1Identity` configured with an owner and an approved claim signer:

```solidity
new ClaimIssuer(issuer_owner, claim_signer);
```

The owner can rotate signers with:

```solidity
addClaimSigner(signer);
removeClaimSigner(signer);
```

This keeps the example focused on identity claims rather than general-purpose key management.

## Claims

Claims are stored on the subject identity by issuer and topic:

```solidity
claimId = keccak256(abi.encode(issuer, topic));
```

A claim stores:

```solidity
Claim({
    topic: topic,
    scheme: SCHEME_ECDSA,
    issuer: issuer_address,
    signature: signature,
    data: data,
    uri: uri
});
```

For the tests in this repo:

```solidity
INVESTOR_ACCREDITATION_TOPIC -> abi.encode(true)
GEOGRAPHIC_LOCATION_TOPIC    -> bytes("Texas") or bytes("California")
```

The registry treats both topics as required eligibility claims. Accreditation is a boolean claim, while geographic
location is a location value claim with multiple allowed values.

## Claim Signatures

The claim signer signs a digest derived from the subject identity address, claim topic, and claim data:

```solidity
claimHash = keccak256(abi.encode(identity, topic, data));
claimDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", claimHash));
```

The subject identity accepts `addClaim(topic, scheme, issuer, signature, data, uri)` only when the issuer contract confirms
that the signature is valid for one of its approved claim signers.

## Compatibility Intent

The identity contract is intentionally small, but the verification surface follows the ERC-735 / ONCHAINID claim-holder
model:

```solidity
getClaimIdsByTopic(topic)
getClaim(claimId)
addClaim(topic, scheme, issuer, signature, data, uri)
```

The issuer side exposes the claim-validity check used by ERC-3643-style flows:

```solidity
isClaimValid(identity, topic, signature, data)
```

That means the simplified registry can be swapped from this local identity implementation to another ERC-734/735-compliant
implementation if it provides the same claim lookup and claim validation behavior.

## Simplified Claim Registry

`tests/contracts/SimplifiedIdentityClaimRegistry.sol` compresses the registry pieces needed for claim-based eligibility
into one helper contract. ERC-3643 can be accommodated by using this same outer verification shape:

```solidity
simplifiedClaimRegistry.registerIdentity(wallet, identity);
simplifiedClaimRegistry.addClaimTopic(INVESTOR_ACCREDITATION_TOPIC);
simplifiedClaimRegistry.addClaimTopic(GEOGRAPHIC_LOCATION_TOPIC);
simplifiedClaimRegistry.addAllowedClaimData(INVESTOR_ACCREDITATION_TOPIC, abi.encode(true));
simplifiedClaimRegistry.addAllowedClaimData(GEOGRAPHIC_LOCATION_TOPIC, bytes("Texas"));
simplifiedClaimRegistry.addAllowedClaimData(GEOGRAPHIC_LOCATION_TOPIC, bytes("California"));
simplifiedClaimRegistry.addTrustedIssuer(accreditationIssuer, topics);
simplifiedClaimRegistry.addTrustedIssuer(geographicLocationIssuer, topics);
simplifiedClaimRegistry.isVerified(wallet);
```

Inside `isVerified`, the registry checks an active claim as follows:

1. Call `getClaimIdsByTopic(topic)` on the subject identity.
2. Call `getClaim(claimId)` for each claim ID.
3. Check whether `claim.issuer` is trusted for that topic.
4. Call `IClaimIssuer(claim.issuer).isClaimValid(identity, claim.topic, claim.signature, claim.data)`.
5. Check whether `claim.data` is in the allowed data set configured for that topic.

## ERC-3643 Subset

`src/erc3643` adds a focused ERC-3643-style token layer on top of the v1 claim identity model. It lives in this package
because ERC-3643 consumes ERC-735 / ONCHAINID-style identity claims rather than introducing a separate identity format.

The subset includes:

- `ERC3643ClaimTopicsRegistry`: the claim topics required by the token;
- `ERC3643TrustedIssuersRegistry`: which claim issuers are trusted for each topic;
- `ERC3643IdentityRegistry`: wallet-to-identity registration plus `isVerified(wallet)`;
- `ERC3643LocationComplianceModule`: token-specific geographic policy, allowing Texas or California in the tests;
- `ERC3643PermissionedToken`: a minimal permissioned token that checks both identity verification and compliance.

The transfer path is:

```solidity
identityRegistry.isVerified(to);
locationCompliance.canTransfer(from, to, amount);
token.transfer(to, amount);
```

`tests/ERC3643PermissionedToken.t.sol` demonstrates the concrete Bob/Ivan/Sam flow:

1. Bob's issuer signs Ivan's accreditation claim.
2. A location issuer signs Ivan's geographic location claim.
3. The token trusts those issuers for their topics.
4. The token allows a transfer to Ivan only when `isVerified(ivan)` passes and the location module accepts Ivan's
   location.

This keeps geography where it belongs in an ERC-3643-style design: the identity stores the location claim as evidence,
while the token compliance module decides which locations are allowed for that token.

## Links

- [ERC-734 Reference](https://eips.ethereum.org/EIPS/eip-734)
- [ERC-725 Reference](https://eips.ethereum.org/EIPS/eip-725)
- [ERC-735 Reference](https://eips.ethereum.org/EIPS/eip-735)
- [ERC-3643 Reference](https://eips.ethereum.org/EIPS/eip-3643)

## License

This project is licensed under MIT — see the [LICENSE](LICENSE.md) file for details.
