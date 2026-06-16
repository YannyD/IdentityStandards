# Identity Standards and Implementation: ERC-725 v2

This repo gives an example of how the ERC-725 v2 standard can be used to post and verify identity claims using only the
single store model of ERC-725Y. It is the counterpart to another standards and implementation repo for ERC-725 v1 (EIP
734/735) models. While most new identity standards have been built on top of ERC-725 v1, the v2 standard can be more
efficient and flexible for many use cases.

## Standard Implementation

ERC-725Y stores arbitrary data as `bytes32` keys mapped to `bytes` values. This implementation uses that single
key-value store for identity claims while also preserving the provenance of each claim. A claim can be posted by any
address, but it is accepted only if the supplied EIP-712 signature matches the claimed signer, subject, key, value, and
nonce. Third parties can then read the stored value, find the related signed claim record, and check whether the signer
is one they trust. The `ERC725YSignedClaimStore` contract writes the following entries for each signed claim:

1. data key -> the claim data value The basic claim data key is linked to its value.

Ex: INVESTOR_ACCREDITATION_STATUS_DATA_KEY -> true

2. claim key -> signed claim data

A claim key is defined by

claimKey = keccak256(abi.encode(signer_address, subject_address, dataKey, keccak256(dataValue)));

and the signed claim data is built by

signedData = abi.encode( signer_address, postedBy_address, subject_address, dataKey, dataValue, nonce, signature );

where the signature is generated using the EIP-712 standard for signed type data. The signer is taking

{ subject: wallet_address, dataKey: INVESTOR_ACCREDITATION_STATUS_DATA_KEY, dataValueHash: keccak256(dataValue), nonce:
currentSignerNonce }

and combining it with the domain separator of the ERC-725Y contract to produce a signature that can be verified
on-chain.

3. latest claim pointer -> claim key

latestClaimPointerKey = keccak256(abi.encodePacked("ERC725Y.latestClaim", dataKey));

This allows a third party to use the data key to find the correct claim key, which can be used to verify the signer who
originally posted the claim. The `getLatestClaim(dataKey)` helper follows this pointer and returns the decoded signed
claim record.

These data store additions are performed by `ERC725YSignedClaimStore.setDataWithSignature`.

In order to locate the claim data for a given data key, a third party can call `getLatestClaim(dataKey)`, which will
return the decoded claim record with all of the relevant information, including the signer and signature. The third
party can then check whether the signer is one they trust, and if so, they can use the claim data value with confidence
in its provenance.

## Links

- [ERC-725X/725Y Implementation Reference](https://eips.ethereum.org/EIPS/eip-725)

## License

This project is licensed under MIT — see the [LICENSE](LICENSE.md) file for details.
