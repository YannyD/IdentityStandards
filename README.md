# Identity Standards Comparison

This repository compares two ways to model reusable identity claims onchain:

- `erc-725-v1`: ERC-725 v1 / ERC-734 / ERC-735 / ONCHAINID-style claim identities. ERC-3643 permissioned-token compliance is implemented on top of this model as an example.

- `erc-725-v2`: ERC-725Y-style signed attestations stored as key-value data.

## Standards Links

- [ERC-725 v1 historical proposal](https://github.com/ethereum/EIPs/issues/725): archived smart-contract account
  proposal that led into the older identity/account lineage.
- [ERC-725 current/v2-style standard](https://eips.ethereum.org/EIPS/eip-725): current ERC-725X / ERC-725Y
  key-value storage and execution standard.
- [ERC-734 historical Key Manager proposal](https://github.com/ethereum/EIPs/issues/734): archived key-management
  proposal associated with the older ERC-725 v1 identity model.
- [ERC-735 historical Claim Holder proposal](https://github.com/ethereum/EIPs/issues/735): archived claim-holder proposal
  used by ONCHAINID / ERC-3643-style identity claims.
- [ERC-3643 / T-REX standard](https://eips.ethereum.org/EIPS/eip-3643): permissioned token, identity registry, trusted
  issuers, claim topics, and compliance interfaces.
- [ERC-3643 docs](https://docs.erc3643.org/erc-3643): protocol documentation for permissioned tokens and the
  associated identity/compliance system.

## Repository Map

```text
erc-725-v1/
  src/
    ERC725V1Identity.sol
    ClaimIssuer.sol
    erc3643/
      ERC3643ClaimTopicsRegistry.sol
      ERC3643TrustedIssuersRegistry.sol
      ERC3643IdentityRegistry.sol
      ERC3643LocationComplianceModule.sol
      ERC3643PermissionedToken.sol
  tests/
    ERC725V1Identity.t.sol
    ERC3643PermissionedToken.t.sol

erc-725-v2/
  src/
    ERC725Y.sol
    ERC725YSignedClaimStore.sol
  tests/
    ERC725Tests.t.sol
```

## Model 1: ERC-725 v1 / ERC-735 Claims

The v1 model stores structured claims directly on an identity contract:

```solidity
Claim({
    topic: topic,
    scheme: SCHEME_ECDSA,
    issuer: issuer,
    signature: signature,
    data: data,
    uri: uri
});
```

Claims are grouped by numeric topic. A verifier reads claims by topic, checks that the issuer is trusted for that topic,
then asks the issuer whether the signature is valid:

```solidity
IClaimIssuer(claim.issuer).isClaimValid(identity, topic, signature, data);
```

This is the lineage used by ERC-3643 / ONCHAINID-style systems.

## ERC-3643 as a v1 Subset

The `erc-725-v1/src/erc3643` directory shows how a permissioned token can consume v1 claims:

- claim topics define what evidence is required;
- trusted issuers define who may issue that evidence;
- the identity registry maps wallets to identity contracts and exposes `isVerified(wallet)`;
- compliance modules define token-specific policy, such as allowed locations;
- the token checks both identity verification and compliance before minting or transferring.

The concrete test story uses:

- accreditation claim: `abi.encode(true)`;
- geographic location claim: `bytes("Texas")` or `bytes("California")`;
- rejection for missing identity, missing required claims, or a location outside the token policy.

## Model 2: ERC-725Y Signed Attestations

The v2 model uses ERC-725Y key-value storage with signed attestations:

```text
dataKey + signer -> signed attestation
```

It does not use ERC-735 claim topics. Instead, a verifier discovers all signers for a data key, checks whether any signer
is trusted, verifies the stored signature, and decodes the value.

This model is useful for comparing a more data-key-oriented ERC-725Y approach against the older claim-topic model.

## Run Tests

Each directory is its own Foundry project:

```bash
cd erc-725-v1
forge test
```

```bash
cd erc-725-v2
forge test
```

## Reading Order

1. Start with `erc-725-v1/tests/ERC725V1Identity.t.sol` to see claim issuance and verification.
2. Read `erc-725-v1/tests/ERC3643PermissionedToken.t.sol` to see how a token consumes those claims.
3. Read `erc-725-v2/tests/ERC725Tests.t.sol` to compare the ERC-725Y signed-attestation model.
