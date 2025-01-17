// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./ExpiryTimestamp.sol";
import "./SingleCollateralBond.sol";
import "./MetaDataStore.sol";
import "./Redeemable.sol";
import "../Version.sol";
import "./Bond.sol";
import "../sweep/SweepERC20.sol";

/**
 * @title A Bond is an issuance of debt tokens, which are exchange for deposit of collateral.
 *
 * @notice A single type of ERC20 token is accepted as collateral.
 *
 * The Bond uses a single redemption model. Before redemption, receiving and slashing collateral is permitted,
 * while after redemption, redeem (by guarantors) or complete withdrawal (by owner) is allowed.
 *
 * @dev A single token type is held by the contract as collateral, with the Bond ERC20 token being the debt.
 */
abstract contract ERC20SingleCollateralBond is
    ERC20Upgradeable,
    ExpiryTimestamp,
    SingleCollateralBond,
    MetaDataStore,
    OwnableUpgradeable,
    PausableUpgradeable,
    Redeemable,
    SweepERC20,
    Version
{
    struct Slash {
        string reason;
        uint256 collateralAmount;
    }

    Slash[] private _slashes;

    // Multiplier / divider for four decimal places, used in redemption ratio calculation.
    uint256 private constant _REDEMPTION_RATIO_ACCURACY = 1e4;

    /*
     * Collateral that is held by the bond, owed to the Guarantors (unless slashed).
     *
     * Kept to guard against the edge case of collateral tokens being directly transferred
     * (i.e. transfer in the collateral contract, not via deposit) to the contract address inflating redemption amounts.
     */
    uint256 private _collateral;

    uint256 private _collateralSlashed;

    address private _collateralTokens;

    uint256 private _debtTokensInitialSupply;

    // Balance of debts tokens held by guarantors, double accounting avoids potential affects of any minting/burning
    uint256 private _debtTokensOutstanding;

    // Balance of debt tokens held by the Bond when redemptions were allowed.
    uint256 private _debtTokensRedemptionExcess;

    // Minimum debt holding allowed in the pre-redemption state.
    uint256 private _minimumDeposit;

    /*
     * Ratio value between one (100% bond redeem) and zero (0% redeem), accuracy defined by _REDEMPTION_RATIO_ACCURACY.
     *
     * Calculated only once, when the redemption is allowed. Ratio will be one, unless slashing has occurred.
     */
    uint256 private _redemptionRatio;

    address private _treasury;

    event AllowRedemption(address indexed authorizer, string reason);
    event DebtIssue(
        address indexed receiver,
        address indexed debTokens,
        uint256 debtAmount
    );
    event Deposit(
        address indexed depositor,
        address indexed collateralTokens,
        uint256 collateralAmount
    );
    event Expire(
        address indexed treasury,
        address indexed collateralTokens,
        uint256 collateralAmount,
        address indexed instigator
    );
    event PartialCollateral(
        address indexed collateralTokens,
        uint256 collateralAmount,
        address indexed debtTokens,
        uint256 debtRemaining,
        address indexed instigator
    );
    event FullCollateral(
        address indexed collateralTokens,
        uint256 collateralAmount,
        address indexed instigator
    );
    event Redemption(
        address indexed redeemer,
        address indexed debtTokens,
        uint256 debtAmount,
        address indexed collateralTokens,
        uint256 collateralAmount
    );
    event SlashDeposits(
        address indexed collateralTokens,
        uint256 collateralAmount,
        string reason,
        address indexed instigator
    );
    event WithdrawCollateral(
        address indexed treasury,
        address indexed collateralTokens,
        uint256 collateralAmount,
        address indexed instigator
    );

    /**
     *  @notice Moves all remaining collateral to the Treasury and pauses the bond.
     *
     *  @dev A fail safe, callable by anyone after the Bond has expired.
     *       If control is lost, this can be used to move all remaining collateral to the Treasury,
     *       after which petitions for redemption can be made.
     *
     *  Expiry operates separately to pause, so a paused contract can be expired (fail safe for loss of control).
     */
    function expire() external whenBeyondExpiry {
        uint256 collateralBalance = IERC20Upgradeable(_collateralTokens)
            .balanceOf(address(this));
        require(collateralBalance > 0, "Bond: no collateral remains");

        emit Expire(
            _treasury,
            _collateralTokens,
            collateralBalance,
            _msgSender()
        );

        bool transferred = IERC20Upgradeable(_collateralTokens).transfer(
            _treasury,
            collateralBalance
        );
        require(transferred, "Bond: collateral transfer failed");

        _pauseSafely();
    }

    function pause() external override whenNotPaused onlyOwner {
        _pause();
    }

    function redeem(uint256 amount)
        external
        override
        whenNotPaused
        whenRedeemable
    {
        require(amount > 0, "Bond: too small");
        require(balanceOf(_msgSender()) >= amount, "Bond: too few debt tokens");

        uint256 totalSupply = totalSupply() - _debtTokensRedemptionExcess;
        uint256 redemptionAmount = _redemptionAmount(amount, totalSupply);
        _collateral -= redemptionAmount;
        _debtTokensOutstanding -= redemptionAmount;

        emit Redemption(
            _msgSender(),
            address(this),
            amount,
            _collateralTokens,
            redemptionAmount
        );

        _burn(_msgSender(), amount);

        // Slashing can reduce redemption amount to zero
        if (redemptionAmount > 0) {
            bool transferred = IERC20Upgradeable(_collateralTokens).transfer(
                _msgSender(),
                redemptionAmount
            );
            require(transferred, "Bond: collateral transfer failed");
        }
    }

    function unpause() external override whenPaused onlyOwner {
        _unpause();
    }

    function slash(uint256 amount, string calldata reason)
        external
        override
        whenNotPaused
        whenNotRedeemable
        onlyOwner
    {
        require(amount > 0, "Bond: too small");
        require(amount <= _collateral, "Bond: too large");

        _collateral -= amount;
        _collateralSlashed += amount;

        emit SlashDeposits(_collateralTokens, amount, reason, _msgSender());

        _slashes.push(Slash(reason, amount));

        bool transferred = IERC20Upgradeable(_collateralTokens).transfer(
            _treasury,
            amount
        );
        require(transferred, "Bond: collateral transfer failed");
    }

    function setMetaData(string calldata data)
        external
        override
        whenNotPaused
        onlyOwner
    {
        return _setMetaData(data);
    }

    function setTreasury(address replacement)
        external
        override
        whenNotPaused
        onlyOwner
    {
        require(replacement != address(0), "Bond: treasury is zero address");
        _treasury = replacement;
        _setTokenSweepBeneficiary(replacement);
    }

    function sweepERC20Tokens(address tokens, uint256 amount)
        external
        override
        whenNotPaused
        onlyOwner
    {
        require(tokens != _collateralTokens, "Bond: no collateral sweeping");
        _sweepERC20Tokens(tokens, amount);
    }

    function withdrawCollateral()
        external
        override
        whenNotPaused
        whenRedeemable
        onlyOwner
    {
        uint256 collateralBalance = IERC20Upgradeable(_collateralTokens)
            .balanceOf(address(this));
        require(collateralBalance > 0, "Bond: no collateral remains");

        emit WithdrawCollateral(
            _treasury,
            _collateralTokens,
            collateralBalance,
            _msgSender()
        );

        bool transferred = IERC20Upgradeable(_collateralTokens).transfer(
            _treasury,
            collateralBalance
        );
        require(transferred, "Bond: collateral transfer failed");
    }

    /**
     * @notice How much collateral held by the bond is owned to the Guarantors.
     *
     * @dev  Collateral has come from guarantors, with the balance changes on deposit, redeem, slashing and flushing.
     *      This value may differ to balanceOf(this), if collateral tokens have been directly transferred
     *      i.e. direct transfer interaction with the token contract, rather then using the Bond functions.
     */
    function collateral() external view returns (uint256) {
        return _collateral;
    }

    /**
     * @notice The ERC20 contract being used as collateral.
     */
    function collateralTokens() external view returns (address) {
        return address(_collateralTokens);
    }

    /**
     * @notice Sum of collateral moved from the Bond to the Treasury by slashing.
     *
     * @dev Other methods of performing moving of collateral outside of slashing, are not included.
     */
    function collateralSlashed() external view returns (uint256) {
        return _collateralSlashed;
    }

    /**
     * @notice Balance of debt tokens held by the bond.
     *
     * @dev Number of debt tokens that can still be swapped for collateral token (if before redemption state),
     *          or the amount of under-collateralization (if during redemption state).
     *
     */
    function debtTokens() external view returns (uint256) {
        return _debtTokensRemaining();
    }

    /**
     * @notice Balance of debt tokens held by the guarantors.
     *
     * @dev Number of debt tokens still held by Guarantors. The number only reduces when guarantors redeem
     *          (swap their debt tokens for collateral).
     */
    function debtTokensOutstanding() external view returns (uint256) {
        return _debtTokensOutstanding;
    }

    /**
     * @notice Balance of debt tokes outstanding when the redemption state was entered.
     *
     * @dev As the collateral deposited is a 1:1, this is amount of collateral that was not received.
     *
     * @return zero if redemption is not yet allowed or full collateral was met, otherwise the number of debt tokens
     *          remaining without matched deposit when redemption was allowed,
     */
    function excessDebtTokens() external view returns (uint256) {
        return _debtTokensRedemptionExcess;
    }

    /**
     * @notice Debt tokens created on Bond initialization.
     *
     * @dev Number of debt tokens minted on init. The total supply of debt tokens will decrease, as redeem burns them.
     */
    function initialDebtTokens() external view returns (uint256) {
        return _debtTokensInitialSupply;
    }

    /**
     * @notice Minimum amount of debt allowed for the created Bonds.
     *
     * @dev Avoids micro holdings, as some operations cost scale linear to debt holders.
     *      Once an account holds the minimum, any deposit from is acceptable as their holding is above the minimum.
     */
    function minimumDeposit() external view returns (uint256) {
        return _minimumDeposit;
    }

    function treasury() external view returns (address) {
        return _treasury;
    }

    function getSlashes() external view returns (Slash[] memory) {
        return _slashes;
    }

    function getSlashByIndex(uint256 index)
        external
        view
        returns (Slash memory)
    {
        require(index < _slashes.length, "Bond: slash does not exist");
        return _slashes[index];
    }

    function hasFullCollateral() public view returns (bool) {
        return _debtTokensRemaining() == 0;
    }

    //slither-disable-next-line naming-convention
    function __ERC20SingleCollateralBond_init(
        Bond.MetaData calldata metadata,
        Bond.Settings calldata configuration,
        address erc20CapableTreasury
    ) internal onlyInitializing {
        require(
            erc20CapableTreasury != address(0),
            "Bond: treasury is zero address"
        );
        require(
            configuration.collateralTokens != address(0),
            "Bond: collateral is zero address"
        );

        __ERC20_init(metadata.name, metadata.symbol);
        __Ownable_init();
        __Pausable_init();
        __ExpiryTimestamp_init(configuration.expiryTimestamp);
        __MetaDataStore_init(metadata.data);
        __Redeemable_init();
        __TokenSweep_init(erc20CapableTreasury);

        _collateralTokens = configuration.collateralTokens;
        _debtTokensInitialSupply = configuration.debtTokenAmount;
        _minimumDeposit = configuration.minimumDeposit;
        _treasury = erc20CapableTreasury;

        _mint(configuration.debtTokenAmount);
    }

    function _allowRedemption(string calldata reason)
        internal
        whenNotPaused
        whenNotRedeemable
        onlyOwner
    {
        _setAsRedeemable(reason);
        emit AllowRedemption(_msgSender(), reason);

        if (_hasDebtTokensRemaining()) {
            _debtTokensRedemptionExcess = _debtTokensRemaining();

            emit PartialCollateral(
                _collateralTokens,
                IERC20Upgradeable(_collateralTokens).balanceOf(address(this)),
                address(this),
                _debtTokensRemaining(),
                _msgSender()
            );
        }

        if (_hasBeenSlashed()) {
            _redemptionRatio = _calculateRedemptionRatio();
        }
    }

    function _deposit(uint256 amount) internal whenNotPaused whenNotRedeemable {
        require(amount > 0, "Bond: too small");
        require(amount <= _debtTokensRemaining(), "Bond: too large");
        require(
            balanceOf(_msgSender()) + amount >= _minimumDeposit,
            "Bond: below minimum"
        );

        _collateral += amount;
        _debtTokensOutstanding += amount;

        emit Deposit(_msgSender(), _collateralTokens, amount);

        bool transferred = IERC20Upgradeable(_collateralTokens).transferFrom(
            _msgSender(),
            address(this),
            amount
        );
        require(transferred, "Bond: collateral transfer failed");

        emit DebtIssue(_msgSender(), address(this), amount);

        _transfer(address(this), _msgSender(), amount);

        if (hasFullCollateral()) {
            emit FullCollateral(
                _collateralTokens,
                IERC20Upgradeable(_collateralTokens).balanceOf(address(this)),
                _msgSender()
            );
        }
    }

    /**
     * @dev Mints additional debt tokens, inflating the supply. Without additional deposits the redemption ratio is affected.
     */
    function _mint(uint256 amount) private whenNotPaused whenNotRedeemable {
        require(amount > 0, "Bond::mint: too small");
        _mint(address(this), amount);
    }

    /**
     *  @dev Pauses the Bond if not already paused. If already paused, does nothing (no revert).
     */
    function _pauseSafely() private {
        if (!paused()) {
            _pause();
        }
    }

    /**
     * @dev Collateral is deposited at a 1 to 1 ratio, however slashing can change that lower.
     */
    function _redemptionAmount(uint256 amount, uint256 totalSupply)
        private
        view
        returns (uint256)
    {
        if (_collateral == totalSupply) {
            return amount;
        } else {
            return _applyRedemptionRation(amount);
        }
    }

    function _applyRedemptionRation(uint256 amount)
        private
        view
        returns (uint256)
    {
        return (_redemptionRatio * amount) / _REDEMPTION_RATIO_ACCURACY;
    }

    /**
     * @return Redemption ration float value as an integer.
     *           The float has been multiplied by _REDEMPTION_RATIO_ACCURACY, with any excess accuracy floored (lost).
     */
    function _calculateRedemptionRatio() private view returns (uint256) {
        return
            (_REDEMPTION_RATIO_ACCURACY * _collateral) /
            (totalSupply() - _debtTokensRedemptionExcess);
    }

    /**
     * @dev The balance of debt token held; amount of debt token that are awaiting collateral swap.
     */
    function _debtTokensRemaining() private view returns (uint256) {
        return balanceOf(address(this));
    }

    /**
     * @dev Whether the Bond has been slashed. Assumes a 1:1 deposit ratio (collateral to debt).
     */
    function _hasBeenSlashed() private view returns (bool) {
        return _collateral != (totalSupply() - _debtTokensRedemptionExcess);
    }

    /**
     * @dev Whether the Bond has held debt tokens.
     */
    function _hasDebtTokensRemaining() private view returns (bool) {
        return _debtTokensRemaining() > 0;
    }
}
