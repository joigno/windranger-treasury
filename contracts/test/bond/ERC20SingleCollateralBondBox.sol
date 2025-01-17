// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "../../bond/ERC20SingleCollateralBond.sol";

contract ERC20SingleCollateralBondBox is ERC20SingleCollateralBond {
    function allowRedemption(string calldata reason) external override {
        _allowRedemption(reason);
    }

    function deposit(uint256 amount) external override {
        _deposit(amount);
    }

    function initialize(
        Bond.MetaData calldata metadata,
        Bond.Settings calldata configuration,
        address treasury
    ) external initializer {
        __ERC20SingleCollateralBond_init(metadata, configuration, treasury);
    }

    function updateRewardTimeLock(address tokens, uint128 timeLock)
        external
        override
    {}
}
