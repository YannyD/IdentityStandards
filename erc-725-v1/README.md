# Identity Standards and Implementation: ERC-725 v1

This repo shows the older ERC-725 v1 / ONCHAINID identity-claim pattern used by ERC-3643-style permissioned-token
systems. It focuses only on the parts needed to compare claim issuance and verification with the ERC-725 v2 example.

The v1 lineage stores claims as structured records on an identity:

- a claim has a topic, scheme, issuer, signature, data, and URI;
- a trusted issuer contract validates whether the signature came from one of its approved claim signers;
- an ERC-3643-style identity registry records which wallet owns which identity, which claim topics are required, and which
  issuers are trusted for each topic;
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

For an accreditation claim, `data` can be `abi.encode(true)`.

## Claim Signatures

The claim signer signs a digest derived from the subject identity address, claim topic, and claim data:

```solidity
claimHash = keccak256(abi.encode(identity, topic, data));
claimDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", claimHash));
```

The subject identity accepts `addClaim(topic, scheme, issuer, signature, data, uri)` only when the issuer contract confirms
that the signature is valid for one of its approved claim signers.

## ERC-3643-Style Verification

`tests/contracts/IdentityRegistry.sol` compresses the ERC-3643 registry system into one helper contract. It keeps the
same outer verification shape:

```solidity
identityRegistry.registerIdentity(wallet, identity, 840);
identityRegistry.addClaimTopic(INVESTOR_ACCREDITATION_TOPIC);
identityRegistry.addTrustedIssuer(accreditationIssuer, topics);
identityRegistry.isVerified(wallet);
```

Inside `isVerified`, the registry checks an active claim as follows:

1. Call `getClaimIdsByTopic(topic)` on the subject identity.
2. Call `getClaim(claimId)` for each claim ID.
3. Check whether `claim.issuer` is trusted for that topic.
4. Call `IClaimIssuer(claim.issuer).isClaimValid(identity, claim.topic, claim.signature, claim.data)`.
5. Decode `claim.data` according to the expected claim type.

## Links

- [ERC-725 Reference](https://eips.ethereum.org/EIPS/eip-725)
- [ERC-735 Reference](https://eips.ethereum.org/EIPS/eip-735)
- [ERC-3643 Reference](https://eips.ethereum.org/EIPS/eip-3643)

## License

This project is licensed under MIT — see the [LICENSE](LICENSE.md) file for details.
