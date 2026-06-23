// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

contract ERC3643ClaimTopicsRegistry {
    uint256[] internal claimTopics;
    mapping(uint256 topic => bool required) public isClaimTopicRequired;

    function addClaimTopic(uint256 claimTopic) external {
        if (isClaimTopicRequired[claimTopic]) {
            return;
        }

        isClaimTopicRequired[claimTopic] = true;
        claimTopics.push(claimTopic);
    }

    function removeClaimTopic(uint256 claimTopic) external {
        if (!isClaimTopicRequired[claimTopic]) {
            return;
        }

        isClaimTopicRequired[claimTopic] = false;
        _removeUint256(claimTopics, claimTopic);
    }

    function getClaimTopics() external view returns (uint256[] memory) {
        return claimTopics;
    }

    function _removeUint256(uint256[] storage values, uint256 value) internal {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == value) {
                values[i] = values[values.length - 1];
                values.pop();
                return;
            }
        }
    }
}
