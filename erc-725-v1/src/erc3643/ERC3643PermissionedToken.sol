// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { ERC3643IdentityRegistry } from "./ERC3643IdentityRegistry.sol";

interface IERC3643Compliance {
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);
}

error ERC3643PermissionedToken_InsufficientBalance(address account, uint256 balance, uint256 amount);
error ERC3643PermissionedToken_TransferNotCompliant(address from, address to, uint256 amount);

contract ERC3643PermissionedToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    ERC3643IdentityRegistry public identityRegistry;
    IERC3643Compliance public compliance;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        ERC3643IdentityRegistry identities,
        IERC3643Compliance complianceModule
    ) {
        name = tokenName;
        symbol = tokenSymbol;
        identityRegistry = identities;
        compliance = complianceModule;
    }

    function mint(address to, uint256 amount) external {
        if (!canTransfer(address(0), to, amount)) {
            revert ERC3643PermissionedToken_TransferNotCompliant(address(0), to, amount);
        }

        totalSupply += amount;
        balanceOf[to] += amount;

        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            allowance[from][msg.sender] = currentAllowance - amount;
        }

        _transfer(from, to, amount);
        return true;
    }

    function canTransfer(address from, address to, uint256 amount) public view returns (bool) {
        return identityRegistry.isVerified(to) && compliance.canTransfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) {
            revert ERC3643PermissionedToken_InsufficientBalance(from, fromBalance, amount);
        }

        if (!canTransfer(from, to, amount)) {
            revert ERC3643PermissionedToken_TransferNotCompliant(from, to, amount);
        }

        balanceOf[from] = fromBalance - amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
    }
}
