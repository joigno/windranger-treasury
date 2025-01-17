// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "./BondCreator.sol";
import "./BondCurator.sol";
import "./BondPortal.sol";
import "./Bond.sol";
import "../dao-configuration/DaoConfiguration.sol";
import "../Version.sol";
import "../sweep/SweepERC20.sol";

/**
 * @title Mediates between a Bond creator and Bond curator.
 *
 * @dev Orchestrates a BondCreator and BondCurator to provide a single function to aggregate the various calls
 *      providing a single function to create and setup a bond for management with the curator.
 */
contract BondMediator is
    BondCurator,
    BondPortal,
    DaoConfiguration,
    SweepERC20,
    UUPSUpgradeable,
    Version
{
    BondCreator private _creator;

    event BondCreatorUpdate(
        address indexed previousCreator,
        address indexed updateCreator,
        address indexed instigator
    );

    /**
     * @notice The _msgSender() is given membership of all roles, to allow granting and future renouncing after others
     *      have been setup.
     *
     * @param factory A deployed BondCreator contract to use when creating bonds.
     * @param treasury Beneficiary of any token sweeping.
     */
    function initialize(address factory, address treasury)
        external
        initializer
    {
        require(
            AddressUpgradeable.isContract(factory),
            "BM: creator not a contract"
        );

        __BondCurator_init();
        __DaoConfiguration_init();
        __UUPSUpgradeable_init();
        __TokenSweep_init(treasury);

        _creator = BondCreator(factory);
    }

    function createDao(address erc20CapableTreasury)
        external
        override
        atLeastDaoCreatorRole
        returns (uint256)
    {
        uint256 id = _daoConfiguration(erc20CapableTreasury);
        _grantDaoCreatorAdminRoleInTheirDao(id);

        emit CreateDao(id, erc20CapableTreasury, _msgSender());

        return id;
    }

    function createManagedBond(
        uint256 daoId,
        Bond.MetaData calldata metadata,
        Bond.Settings calldata configuration,
        Bond.TimeLockRewardPool[] calldata rewards
    )
        external
        override
        whenNotPaused
        atLeastDaoMeepleRole(daoId)
        returns (address)
    {
        require(_isValidDaoId(daoId), "BM: invalid DAO Id");
        require(
            isAllowedDaoCollateral(daoId, configuration.collateralTokens),
            "BM: collateral not whitelisted"
        );

        address bond = _creator.createBond(
            metadata,
            configuration,
            rewards,
            _daoTreasury(daoId)
        );

        // Reentrancy warning from an emitted event, which needs the Bond, created by an external call above.
        //slither-disable-next-line reentrancy-events
        _addBond(daoId, bond);

        return bond;
    }

    /**
     * @notice Updates the Bond creator reference.
     *
     * @param factory Contract address for the new BondCreator to use from now onwards when creating managed bonds.
     */
    function setBondCreator(address factory)
        external
        whenNotPaused
        atLeastSysAdminRole
    {
        require(
            AddressUpgradeable.isContract(factory),
            "BM: creator not a contract"
        );
        address previousCreator = address(_creator);
        require(factory != previousCreator, "BM: matches existing");

        emit BondCreatorUpdate(address(_creator), factory, _msgSender());
        _creator = BondCreator(factory);
    }

    /**
     * @notice Permits updating the default DAO treasury address.
     *
     * @dev Only applies for bonds created after the update, previously created bond treasury addresses remain unchanged.
     */
    function setDaoTreasury(uint256 daoId, address replacement)
        external
        whenNotPaused
        atLeastDaoAdminRole(daoId)
    {
        _setDaoTreasury(daoId, replacement);
    }

    /**
     * @notice Permits updating the meta data for the DAO.
     */
    function setDaoMetaData(uint256 daoId, string calldata replacement)
        external
        whenNotPaused
        atLeastDaoAdminRole(daoId)
    {
        _setDaoMetaData(daoId, replacement);
    }

    function updateTokenSweepBeneficiary(address newBeneficiary)
        external
        whenNotPaused
        onlySuperUserRole
    {
        _setTokenSweepBeneficiary(newBeneficiary);
    }

    /**
     * @notice Permits the owner to remove a collateral token from being accepted in future bonds.
     *
     * @dev Only applies for bonds created after the removal, previously created bonds remain unchanged.
     *
     * @param erc20CollateralTokens token to remove from whitelist
     * @param daoId The DAO who is having the collateral token removed from their whitelist.
     */
    function removeWhitelistedCollateral(
        uint256 daoId,
        address erc20CollateralTokens
    ) external whenNotPaused atLeastDaoAdminRole(daoId) {
        _removeWhitelistedDaoCollateral(daoId, erc20CollateralTokens);
    }

    function sweepERC20Tokens(address tokens, uint256 amount)
        external
        whenNotPaused
        onlySuperUserRole
    {
        _sweepERC20Tokens(tokens, amount);
    }

    /**
     * @notice Adds an ERC20 token to the collateral whitelist.
     *
     * @dev When a bond is created, the tokens used as collateral must have been whitelisted.
     *
     * @param daoId The DAO who is having the collateral token whitelisted.
     * @param erc20CollateralTokens Whitelists the token from now onwards.
     *      On bond creation the tokens address used is retrieved by symbol from the whitelist.
     */
    function whitelistCollateral(uint256 daoId, address erc20CollateralTokens)
        external
        whenNotPaused
        atLeastDaoAdminRole(daoId)
    {
        _whitelistDaoCollateral(daoId, erc20CollateralTokens);
    }

    function bondCreator() external view returns (address) {
        return address(_creator);
    }

    /**
     * @notice Permits only the relevant admins to perform proxy upgrades.
     *
     * @dev Only applicable when deployed as implementation to a UUPS proxy.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        atLeastSysAdminRole
    {}

    function _grantDaoCreatorAdminRoleInTheirDao(uint256 daoId) private {
        if (_hasGlobalRole(Roles.DAO_CREATOR, _msgSender())) {
            _grantDaoRole(daoId, Roles.DAO_ADMIN, _msgSender());
        }
    }
}
