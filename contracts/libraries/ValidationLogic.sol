// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.8;

import {SafeMath} from '@openzeppelin/contracts/math/SafeMath.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {ReserveLogic} from './ReserveLogic.sol';
import {UserLogic} from './UserLogic.sol';
import {GenericLogic} from './GenericLogic.sol';
import {WadRayMath} from './WadRayMath.sol';
import {PercentageMath} from './PercentageMath.sol';
import {UniversalERC20} from './UniversalERC20.sol';
import {ReserveConfiguration} from './ReserveConfiguration.sol';
import {IPriceOracleGetter} from '../interfaces/IPriceOracleGetter.sol';
import {IFeeProvider} from '../interfaces/IFeeProvider.sol';
import '@nomiclabs/buidler/console.sol';

/**
 * @title ReserveLogic library
 * @author Aave
 * @notice Implements functions to validate specific action on the protocol.
 */
library ValidationLogic {
  using ReserveLogic for ReserveLogic.ReserveData;
  using UserLogic for UserLogic.UserReserveData;
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using UniversalERC20 for IERC20;
  using ReserveConfiguration for ReserveConfiguration.Map;

  /**
   * @dev validates a deposit.
   * @param _reserve the reserve state on which the user is depositing
   * @param _amount the amount to be deposited
   */
  function validateDeposit(ReserveLogic.ReserveData storage _reserve, uint256 _amount)
    external
    view
  {
    (bool isActive, bool isFreezed, , ) = _reserve.configuration.getFlags();

    internalValidateReserveStateAndAmount(_reserve, _amount);
  }

  /**
   * @dev validates a redeem.
   * @param _reserve the reserve state from which the user is redeeming
   * @param _reserveAddress the address of the reserve
   * @param _amount the amount to be redeemed
   */
  function validateRedeem(
    ReserveLogic.ReserveData storage _reserve,
    address _reserveAddress,
    uint256 _amount
  ) external view {
    internalValidateReserveStateAndAmount(_reserve, _amount);

    require(msg.sender == _reserve.aTokenAddress, '31');

    uint256 currentAvailableLiquidity = IERC20(_reserveAddress).universalBalanceOf(
      address(_reserve.aTokenAddress)
    );

    require(currentAvailableLiquidity >= _amount, '4');
  }

  struct ValidateBorrowLocalVars {
    uint256 principalBorrowBalance;
    uint256 currentLtv;
    uint256 currentLiquidationThreshold;
    uint256 requestedBorrowAmountETH;
    uint256 amountOfCollateralNeededETH;
    uint256 userCollateralBalanceETH;
    uint256 userBorrowBalanceETH;
    uint256 borrowBalanceIncrease;
    uint256 currentReserveStableRate;
    uint256 availableLiquidity;
    uint256 finalUserBorrowRate;
    uint256 healthFactor;
    ReserveLogic.InterestRateMode rateMode;
    bool healthFactorBelowThreshold;
    bool isActive;
    bool isFreezed;
    bool borrowingEnabled;
    bool stableRateBorrowingEnabled;
  }

  /**
   * @dev validates a borrow.
   * @param _reserve the reserve state from which the user is borrowing
   * @param _user the state of the user for the specific reserve
   * @param _reserveAddress the address of the reserve
   * @param _amount the amount to be borrowed
   * @param _amountInETH the amount to be borrowed, in ETH
   * @param _interestRateMode the interest rate mode at which the user is borrowing
   * @param _maxStableLoanPercent the max amount of the liquidity that can be borrowed at stable rate, in percentage
   * @param _reservesData the state of all the reserves
   * @param _usersData the state of all the users for all the reserves
   * @param _reserves the addresses of all the active reserves
   * @param _oracle the price oracle
   */

  function validateBorrow(
    ReserveLogic.ReserveData storage _reserve,
    UserLogic.UserReserveData storage _user,
    address _reserveAddress,
    uint256 _amount,
    uint256 _amountInETH,
    uint256 _interestRateMode,
    uint256 _maxStableLoanPercent,
    mapping(address => ReserveLogic.ReserveData) storage _reservesData,
    mapping(address => mapping(address => UserLogic.UserReserveData)) storage _usersData,
    address[] calldata _reserves,
    address _oracle
  ) external view {
    ValidateBorrowLocalVars memory vars;

    //internalValidateReserveStateAndAmount(_reserve, _amount);

    (
      vars.isActive,
      vars.isFreezed,
      vars.borrowingEnabled,
      vars.stableRateBorrowingEnabled
    ) = _reserve.configuration.getFlags();

    require(vars.isActive, 'Action requires an active reserve');
    require(!vars.isFreezed, 'Action requires an unfreezed reserve');

    require(vars.borrowingEnabled, '5');

    //validate interest rate mode
    require(
      uint256(ReserveLogic.InterestRateMode.VARIABLE) == _interestRateMode ||
        uint256(ReserveLogic.InterestRateMode.STABLE) == _interestRateMode,
      'Invalid interest rate mode selected'
    );

    //check that the amount is available in the reserve
    vars.availableLiquidity = IERC20(_reserveAddress).universalBalanceOf(
      address(_reserve.aTokenAddress)
    );

    require(vars.availableLiquidity >= _amount, '7');

    (
      vars.userCollateralBalanceETH,
      vars.userBorrowBalanceETH,
      vars.currentLtv,
      vars.currentLiquidationThreshold,
      vars.healthFactor
    ) = GenericLogic.calculateUserAccountData(
      msg.sender,
      _reservesData,
      _usersData,
      _reserves,
      _oracle
    );

    require(vars.userCollateralBalanceETH > 0, 'The collateral balance is 0');

    require(vars.healthFactor > GenericLogic.HEALTH_FACTOR_LIQUIDATION_THRESHOLD, '8');

    //add the current already borrowed amount to the amount requested to calculate the total collateral needed.
    vars.amountOfCollateralNeededETH = vars.userBorrowBalanceETH.add(_amountInETH).percentDiv(
      vars.currentLtv
    ); //LTV is calculated in percentage

    require(
      vars.amountOfCollateralNeededETH <= vars.userCollateralBalanceETH,
      'There is not enough collateral to cover a new borrow'
    );

    /**
     * Following conditions need to be met if the user is borrowing at a stable rate:
     * 1. Reserve must be enabled for stable rate borrowing
     * 2. Users cannot borrow from the reserve if their collateral is (mostly) the same currency
     *    they are borrowing, to prevent abuses.
     * 3. Users will be able to borrow only a relatively small, configurable amount of the total
     *    liquidity
     **/

    if (vars.rateMode == ReserveLogic.InterestRateMode.STABLE) {
      //check if the borrow mode is stable and if stable rate borrowing is enabled on this reserve

      require(vars.stableRateBorrowingEnabled, '11');

      require(
        !_user.useAsCollateral ||
          _reserve.configuration.getLtv() == 0 ||
          _amount > IERC20(_reserve.aTokenAddress).balanceOf(msg.sender),
        '12'
      );

      //calculate the max available loan size in stable rate mode as a percentage of the
      //available liquidity
      uint256 maxLoanSizeStable = vars.availableLiquidity.percentMul(_maxStableLoanPercent);

      require(_amount <= maxLoanSizeStable, '13');
    }
  }

  /**
   * @dev validates a repay.
   * @param _reserve the reserve state from which the user is repaying
   * @param _reserveAddress the address of the reserve
   * @param _amountSent the amount sent for the repayment. Can be an actual value or uint(-1)
   * @param _onBehalfOf the address of the user msg.sender is repaying for
   * @param _stableBorrowBalance the borrow balance of the user
   * @param _variableBorrowBalance the borrow balance of the user
   * @param _actualPaybackAmount the actual amount being repaid
   * @param _msgValue the value passed to the repay() function
   */
  function validateRepay(
    ReserveLogic.ReserveData storage _reserve,
    address _reserveAddress,
    uint256 _amountSent,
    ReserveLogic.InterestRateMode _rateMode,
    address _onBehalfOf,
    uint256 _stableBorrowBalance,
    uint256 _variableBorrowBalance,
    uint256 _actualPaybackAmount,
    uint256 _msgValue
  ) external view {
    bool isActive = _reserve.configuration.getActive();

    require(isActive, 'Action requires an active reserve');

    require(_amountSent > 0, 'Amount must be greater than 0');

    require(
      (_stableBorrowBalance > 0 &&
        ReserveLogic.InterestRateMode(_rateMode) == ReserveLogic.InterestRateMode.STABLE) ||
        (_variableBorrowBalance > 0 &&
          ReserveLogic.InterestRateMode(_rateMode) == ReserveLogic.InterestRateMode.VARIABLE),
      '16'
    );

    require(
      _amountSent != uint256(-1) || msg.sender == _onBehalfOf,
      'To repay on behalf of an user an explicit amount to repay is needed'
    );

    require(
      !IERC20(_reserveAddress).isETH() || _msgValue >= _actualPaybackAmount,
      'Invalid msg.value sent for the repayment'
    );
  }

  /**
   * @dev validates a swap of borrow rate mode.
   * @param _reserve the reserve state on which the user is swapping the rate
   * @param _user the user state for the reserve on which user is swapping the rate
   * @param _stableBorrowBalance the stable borrow balance of the user
   * @param _variableBorrowBalance the stable borrow balance of the user
   * @param _currentRateMode the rate mode of the borrow
   */
  function validateSwapRateMode(
    ReserveLogic.ReserveData storage _reserve,
    UserLogic.UserReserveData storage _user,
    uint256 _stableBorrowBalance,
    uint256 _variableBorrowBalance,
    ReserveLogic.InterestRateMode _currentRateMode
  ) external view {
    (bool isActive, bool isFreezed, , bool stableRateEnabled) = _reserve.configuration.getFlags();

    require(isActive, 'Action requires an active reserve');
    require(!isFreezed, 'Action requires an unfreezed reserve');

    if (_currentRateMode == ReserveLogic.InterestRateMode.STABLE) {
      require(
        _stableBorrowBalance > 0,
        'User does not have a stable rate loan in progress on this reserve'
      );
    } else if (_currentRateMode == ReserveLogic.InterestRateMode.VARIABLE) {
      require(
        _variableBorrowBalance > 0,
        'User does not have a variable rate loan in progress on this reserve'
      );
      /**
       * user wants to swap to stable, before swapping we need to ensure that
       * 1. stable borrow rate is enabled on the reserve
       * 2. user is not trying to abuse the reserve by depositing
       * more collateral than he is borrowing, artificially lowering
       * the interest rate, borrowing at variable, and switching to stable
       **/
      require(stableRateEnabled, '11');

      require(
        !_user.useAsCollateral ||
          _reserve.configuration.getLtv() == 0 ||
          _stableBorrowBalance.add(_variableBorrowBalance) >
          IERC20(_reserve.aTokenAddress).balanceOf(msg.sender),
        '12'
      );
    } else {
      revert('Invalid interest rate mode selected');
    }
  }

  /**
   * @dev validates the choice of a user of setting (or not) an asset as collateral
   * @param _reserve the state of the reserve that the user is enabling or disabling as collateral
   * @param _reserveAddress the address of the reserve
   * @param _reservesData the data of all the reserves
   * @param _usersData the data of all the users
   */
  function validateSetUseReserveAsCollateral(
    ReserveLogic.ReserveData storage _reserve,
    address _reserveAddress,
    mapping(address => ReserveLogic.ReserveData) storage _reservesData,
    mapping(address => mapping(address => UserLogic.UserReserveData)) storage _usersData,
    address[] calldata _reserves,
    address _oracle
  ) external view {
    uint256 underlyingBalance = IERC20(_reserve.aTokenAddress).balanceOf(msg.sender);

    require(underlyingBalance > 0, '22');

    require(
      GenericLogic.balanceDecreaseAllowed(
        _reserveAddress,
        msg.sender,
        underlyingBalance,
        _reservesData,
        _usersData,
        _reserves,
        _oracle
      ),
      'User deposit is already being used as collateral'
    );
  }

  /**
   * @dev validates that the reserve is active and the amount is greater than 0
   * @param _reserve the state of the reserve being validated
   * @param _amount the amount being validated
   */
  function internalValidateReserveStateAndAmount(
    ReserveLogic.ReserveData storage _reserve,
    uint256 _amount
  ) internal view {
    require(_amount > 0, 'Amount must be greater than 0');
  }
}
