// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29;

import { ERC725V1Identity } from "./ERC725V1Identity.sol";

contract ClaimIssuer is ERC725V1Identity {
    constructor(address owner, address claimSigner) ERC725V1Identity(owner) {
        _addClaimSigner(claimSigner);
    }
}
