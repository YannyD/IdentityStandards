# Identity Standards and Implementation: ERC-725 v2

This repo shows how ERC-725 v2 can represent reusable identity attestations with the ERC-725Y key-value store. It is the
counterpart to the ERC-725 v1 identity-claim example, but uses `bytes32` data keys instead of numeric claim topics.

The v2 model in this repo is intentionally attestation-based:

- a data key identifies the claim type, such as investor accreditation status;
- each signer can post one current signed attestation for that data key;
- the identity keeps an enumerable list of signers that have attested to each data key;
- a verifier checks whether any trusted signer has posted a valid true attestation.

## Attestation Storage

`ERC725YSignedClaimStore` verifies an EIP-712 signature before storing an attestation. The signed data binds the subject,
data key, value hash, and signer nonce:

```solidity
SetData({
    subject: wallet_address,
    dataKey: INVESTOR_ACCREDITATION_STATUS_DATA_KEY,
    dataValueHash: keccak256(abi.encode(true)),
    nonce: currentSignerNonce
});
```

The attestation is stored under a key derived from both the claim key and signer:

```solidity
claimKey = keccak256(abi.encodePacked("ERC725Y.claim", dataKey, signer));
```

This lets multiple issuers attest to the same reusable claim key without overwriting each other:

```text
identity.walletHolder.investorAccreditationStatus + Bob   -> Bob's signed attestation
identity.walletHolder.investorAccreditationStatus + Alice -> Alice's signed attestation
identity.walletHolder.investorAccreditationStatus + Carol -> Carol's signed attestation
```

The raw `dataKey` itself is not treated as a canonical latest value for accreditation. The attestations are the source of
truth.

## Discovery

For each data key, the store maintains a signer index:

```solidity
getClaimSignersByDataKey(dataKey) -> address[]
```

The duplicate guard prevents the same signer from being pushed again when they update their attestation. A verifier can
discover all attesters for a data key, filter them through its trusted signer list, verify the stored signature, and decode
the value.

## Verification

A verifier can check accreditation as follows:

1. Call `getClaimSignersByDataKey(accreditationKey)`.
2. For each signer, skip if the signer is not trusted.
3. Call `getClaim(accreditationKey, signer)`.
4. Rebuild the EIP-712 digest with `hashSetData(claim.subject, claim.dataKey, keccak256(claim.dataValue), claim.nonce)`.
5. Recover the signer from `claim.signature` and compare it to `claim.signer`.
6. Decode `claim.dataValue`; if any trusted valid attestation is `true`, the identity satisfies the accreditation check.

`tests/contracts/AccreditationVerifier.sol` demonstrates this flow.

## Links

- [ERC-725X/725Y Implementation Reference](https://eips.ethereum.org/EIPS/eip-725)

## License

This project is licensed under MIT — see the [LICENSE](LICENSE.md) file for details.
