# Identity Standards and Implementation: ERC-725 v1

This repo shows the older ERC-725 v1 identity pattern used by ONCHAINID, ERC-3643, and similar permissioned-token
systems. Instead of storing arbitrary values directly under ERC-725Y data keys, the v1 model separates identity control
into keys and claims:

- ERC-734-style keys describe who can manage the identity or sign claims.
- ERC-735-style claims describe facts about the identity, such as accreditation status.
- Trusted claim issuers validate claims through their own claim-signer keys.

## Standard Implementation

`ERC725V1Identity` implements a compact version of the key and claim holder pattern.

1. Management keys.

The identity is deployed with an initial management key:

```solidity
new ERC725V1Identity(wallet_address);
```

Internally, addresses are converted to ERC-734-style keys:

```solidity
key = keccak256(abi.encode(account));
```

The management key can add and remove keys with `addKey(key, purpose, keyType)` and `removeKey(key, purpose)`. A key
with purpose `1` is a management key. A key with purpose `3` is a claim signer key.

2. Claim issuers.

`ClaimIssuer` is also an `ERC725V1Identity`, but it starts with a management key and a claim signer key:

```solidity
new ClaimIssuer(issuer_manager_address, claim_signer_address);
```

The issuer validates signatures in `isClaimValid(identity, topic, signature, data)` by recovering the signer from the
claim hash and checking whether that signer has the claim signer purpose.

3. Claims.

Claims are stored on the identity by issuer and topic:

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

4. Claim signatures.

The claim signer signs a digest derived from the identity address, claim topic, and claim data:

```solidity
claimHash = keccak256(abi.encode(identity, topic, data));
claimDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", claimHash));
```

The identity accepts `addClaim(topic, scheme, issuer, signature, data, uri)` only when the issuer contract confirms that
the signature is valid for one of its claim signer keys.

5. Verification.

A verifier can check an active claim as follows:

1. Call `getClaimIdsByTopic(topic)` on the identity.
2. Call `getClaim(claimId)` for each claim ID.
3. Check whether `claim.issuer` is trusted for that topic.
4. Call `IClaimIssuer(claim.issuer).isClaimValid(identity, claim.topic, claim.signature, claim.data)`.
5. Decode `claim.data` according to the expected claim type.

`tests/contracts/AccreditationVerifier.sol` demonstrates this flow for an investor accreditation claim. Historical claim
changes are emitted as `ClaimAdded`, `ClaimChanged`, and `ClaimRemoved` events.

## Links

- [ERC-725 Reference](https://eips.ethereum.org/EIPS/eip-725)
- [ERC-734 Reference](https://eips.ethereum.org/EIPS/eip-734)
- [ERC-735 Reference](https://eips.ethereum.org/EIPS/eip-735)
- [ERC-3643 Reference](https://eips.ethereum.org/EIPS/eip-3643)

## License

This project is licensed under MIT — see the [LICENSE](LICENSE.md) file for details.
