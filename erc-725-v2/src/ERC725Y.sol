pragma solidity ^0.8.8;
import "./ERC173.sol";
import "./ERC165.sol";
import "./interfaces/IERC725Y.sol";
// ERC165 INTERFACE IDs
bytes4 constant _INTERFACEID_ERC725Y = 0x629aa694;

/**
 * @dev reverts when there is not the same number of elements in the lists of data keys and data values
 * when calling setData(bytes32[],bytes[]).
 * @param dataKeysLength the number of data keys in the bytes32[] dataKeys
 * @param dataValuesLength the number of data value in the bytes[] dataValue
 */
error ERC725Y_DataKeysValuesLengthMismatch(
    uint256 dataKeysLength,
    uint256 dataValuesLength
);

contract ERC725Y is ERC173, ERC165, IERC725Y {
    // overrides

    /**
     * @inheritdoc ERC165
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, ERC165)
        returns (bool)
    {
        return
            interfaceId == _INTERFACEID_ERC725Y ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev Map the dataKeys to their dataValues
     */
    mapping(bytes32 => bytes) internal _store;

    /**
     * @inheritdoc IERC725Y
     */
    function getData(bytes32 dataKey)
        public
        view
        virtual
        returns (bytes memory dataValue)
    {
        dataValue = _getData(dataKey);
    }

    /**
     * @inheritdoc IERC725Y
     */
    function getDataBatch(bytes32[] memory dataKeys)
        public
        view
        virtual
        returns (bytes[] memory dataValues)
    {
        dataValues = new bytes[](dataKeys.length);

        for (uint256 i = 0; i < dataKeys.length; i++) {
            dataValues[i] = _getData(dataKeys[i]);
        }

        return dataValues;
    }

    /**
     * @inheritdoc IERC725Y
     */
    function setData(bytes32 dataKey, bytes memory dataValue)
        public
        virtual
        onlyOwner
    {
        _setData(dataKey, dataValue);
    }

    /**
     * @inheritdoc IERC725Y
     */
    function setDataBatch(bytes32[] memory dataKeys, bytes[] memory dataValues)
        public
        virtual
        onlyOwner
    {
        if (dataKeys.length != dataValues.length) {
            revert ERC725Y_DataKeysValuesLengthMismatch(
                dataKeys.length,
                dataValues.length
            );
        }

        for (uint256 i = 0; i < dataKeys.length; i++) {
            _setData(dataKeys[i], dataValues[i]);
        }
    }

    function _getData(bytes32 dataKey)
        internal
        view
        virtual
        returns (bytes memory dataValue)
    {
        return _store[dataKey];
    }

    function _setData(bytes32 dataKey, bytes memory dataValue)
        internal
        virtual
    {
        _store[dataKey] = dataValue;
        emit DataChanged(dataKey, dataValue);
    }
}