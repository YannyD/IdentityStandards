pragma solidity ^0.8.8;
import "./ERC725X.sol";
import "./ERC725Y.sol";

contract ERC725 is ERC725X, ERC725Y {
    /**
     * @inheritdoc ERC165
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC725X, ERC725Y)
        returns (bool)
    {
        return
            interfaceId == _INTERFACEID_ERC725X ||
            interfaceId == _INTERFACEID_ERC725Y ||
            super.supportsInterface(interfaceId);
    }
}