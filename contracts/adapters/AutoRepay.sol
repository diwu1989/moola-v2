// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {EnumerableSet} from '@openzeppelin/contracts/utils/EnumerableSet.sol';

import {BaseUniswapAdapter} from './BaseUniswapAdapter.sol';
import {ILendingPoolAddressesProvider} from '../interfaces/ILendingPoolAddressesProvider.sol';
import {IUniswapV2Router02} from '../interfaces/IUniswapV2Router02.sol';
import {DataTypes} from '../protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../dependencies/openzeppelin/contracts/SafeERC20.sol';

contract AutoRepay is BaseUniswapAdapter {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  struct RepayParams {
    address user;
    address collateralAsset;
    address debtAsset;
    uint256 collateralAmount;
    uint256 debtRepayAmount;
    uint256 rateMode;
    bool useEthPath;
    bool useATokenAsFrom;
    bool useATokenAsTo;
    bool useFlashloan;
  }

  struct UserInfo {
    uint256 minHealthFactor;
    uint256 maxHealthFactor;
  }

  EnumerableSet.AddressSet private _whitelistedAddresses;

  mapping(address => UserInfo) public userInfos;

  uint256 public constant FEE = 10;
  uint256 public constant FEE_DECIMALS = 10000;

  constructor(
    ILendingPoolAddressesProvider addressesProvider,
    IUniswapV2Router02 uniswapRouter,
    address wethAddress
  ) public BaseUniswapAdapter(addressesProvider, uniswapRouter, wethAddress) {}

  function whitelistAddress(address userAddress) public onlyOwner returns (bool) {
    return _whitelistedAddresses.add(userAddress);
  }

  function removeFromWhitelist(address userAddress) public onlyOwner returns (bool) {
    return _whitelistedAddresses.remove(userAddress);
  }

  function isWhitelisted(address userAddress) public view returns (bool) {
    return _whitelistedAddresses.contains(userAddress);
  }

  function getWitelistedAddresses() public view returns (address[] memory) {
    uint256 length = _whitelistedAddresses.length();
    address[] memory addresses = new address[](length);
    for (uint256 i = 0; i < length; i++) {
      addresses[i] = _whitelistedAddresses.at(i);
    }
    return addresses;
  }

  function setMinMaxHealthFactor(uint256 minHealthFactor, uint256 maxHealthFactor) public {
    require(
      maxHealthFactor >= minHealthFactor,
      'maxHealthFactor should be more or equal than minHealthFactor'
    );
    userInfos[msg.sender] = UserInfo({
      minHealthFactor: minHealthFactor,
      maxHealthFactor: maxHealthFactor
    });
  }

  function _checkMinHealthFactor(address user) internal view {
    (, , , , , uint256 healthFactor) = LENDING_POOL.getUserAccountData(user);
    require(
      healthFactor < userInfos[user].minHealthFactor,
      'User health factor must be less than minHealthFactor for user'
    );
  }

  function _checkHealthFactorInRange(address user) internal view {
    (, , , , , uint256 healthFactor) = LENDING_POOL.getUserAccountData(user);
    require(
      healthFactor >= userInfos[user].minHealthFactor &&
        healthFactor <= userInfos[user].maxHealthFactor,
      'User health factor must be in range {from minHealthFactor to maxHealthFactor}'
    );
  }

  /**
   * @dev Uses the received funds from the flash loan to repay a debt on the protocol on behalf of the user. Then pulls
   * the collateral from the user and swaps it to the debt asset to repay the flash loan.
   * The user should give this contract allowance to pull the ATokens in order to withdraw the underlying asset, swap it
   * and repay the flash loan.
   * Supports only one asset on the flash loan.
   * @param assets Address of debt asset
   * @param amounts Amount of the debt to be repaid
   * @param premiums Fee of the flash loan
   * @param params Additional variadic field to include extra params. Expected parameters:
   *   address collateralAsset Address of the reserve to be swapped
   *   uint256 collateralAmount Amount of reserve to be swapped
   *   uint256 rateMode Rate modes of the debt to be repaid
   *   uint256 permitAmount Amount for the permit signature
   *   uint256 deadline Deadline for the permit signature
   *   uint8 v V param for the permit signature
   *   bytes32 r R param for the permit signature
   *   bytes32 s S param for the permit signature
   */
  function executeOperation(
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata premiums,
    address initiator,
    bytes calldata params
  ) external override returns (bool) {
    require(msg.sender == address(LENDING_POOL), 'CALLER_MUST_BE_LENDING_POOL');
    require(initiator == address(this), 'Only this contract can call flashloan');

    (
      RepayParams memory repayParams,
      PermitSignature memory permitSignature,
      address caller
    ) = _decodeParams(params);
    repayParams.debtAsset = assets[0];
    repayParams.debtRepayAmount = amounts[0];

    // Repay debt. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
    IERC20(repayParams.debtAsset).safeApprove(address(LENDING_POOL), 0);
    IERC20(repayParams.debtAsset).safeApprove(address(LENDING_POOL), repayParams.debtRepayAmount);
    uint256 repaidAmount = IERC20(repayParams.debtAsset).balanceOf(address(this));
    LENDING_POOL.repay(
      repayParams.debtAsset,
      repayParams.debtRepayAmount,
      repayParams.rateMode,
      repayParams.user
    );
    repaidAmount = repaidAmount.sub(IERC20(repayParams.debtAsset).balanceOf(address(this)));

    uint256 maxCollateralToSwap = repayParams.collateralAmount;
    if (repaidAmount < repayParams.debtRepayAmount) {
      maxCollateralToSwap = maxCollateralToSwap.mul(repaidAmount).div(repayParams.debtRepayAmount);
    }

    repayParams.collateralAmount = maxCollateralToSwap;
    repayParams.debtRepayAmount = repaidAmount;

    _doSwapAndPullWithFee(repayParams, permitSignature, caller, premiums[0]);

    // Repay flashloan. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
    IERC20(repayParams.debtAsset).safeApprove(address(LENDING_POOL), 0);
    IERC20(repayParams.debtAsset).safeApprove(
      address(LENDING_POOL),
      repayParams.debtRepayAmount.add(premiums[0])
    );

    return true;
  }

  function increaseHealthFactor(
    RepayParams memory repayParams,
    PermitSignature calldata permitSignature
  ) public {
    require(isWhitelisted(msg.sender), 'Caller is not whitelisted');
    _checkMinHealthFactor(repayParams.user);
    if (repayParams.useFlashloan) {
      bytes memory params = abi.encode(repayParams, permitSignature, msg.sender);
      address[] memory assets = new address[](1);
      assets[0] = repayParams.debtAsset;
      uint256[] memory amounts = new uint256[](1);
      amounts[0] = repayParams.debtRepayAmount;
      uint256[] memory modes = new uint256[](1);
      modes[0] = 0;
      LENDING_POOL.flashLoan(address(this), assets, amounts, modes, repayParams.user, params, 0);
    } else {
      DataTypes.ReserveData memory debtReserveData = _getReserveData(repayParams.debtAsset);
      uint256 amountToRepay;
      {
        address debtToken = DataTypes.InterestRateMode(repayParams.rateMode) ==
          DataTypes.InterestRateMode.STABLE
          ? debtReserveData.stableDebtTokenAddress
          : debtReserveData.variableDebtTokenAddress;
        uint256 currentDebt = IERC20(debtToken).balanceOf(repayParams.user);
        amountToRepay = repayParams.debtRepayAmount <= currentDebt
          ? repayParams.debtRepayAmount
          : currentDebt;
      }
      uint256 maxCollateralToSwap = repayParams.collateralAmount;
      if (amountToRepay < repayParams.debtRepayAmount) {
        maxCollateralToSwap = maxCollateralToSwap.mul(amountToRepay).div(
          repayParams.debtRepayAmount
        );
      }
      repayParams.collateralAmount = maxCollateralToSwap;
      repayParams.debtRepayAmount = amountToRepay;
      _doSwapAndPullWithFee(repayParams, permitSignature, msg.sender, 0);

      // Repay debt. Approves 0 first to comply with tokens that implement the anti frontrunning approval fix
      IERC20(repayParams.debtAsset).safeApprove(address(LENDING_POOL), 0);
      IERC20(repayParams.debtAsset).safeApprove(address(LENDING_POOL), repayParams.debtRepayAmount);
      LENDING_POOL.repay(
        repayParams.debtAsset,
        repayParams.debtRepayAmount,
        repayParams.rateMode,
        repayParams.user
      );
    }
    _checkHealthFactorInRange(repayParams.user);
  }

  function _doSwapAndPullWithFee(
    RepayParams memory repayParams,
    PermitSignature memory permitSignature,
    address caller,
    uint256 premium
  ) internal {
    address collateralATokenAddress = _getReserveData(repayParams.collateralAsset).aTokenAddress;
    address debtATokenAddress = _getReserveData(repayParams.debtAsset).aTokenAddress;
    if (repayParams.collateralAsset != repayParams.debtAsset) {
      uint256 amounts0 = _getAmountsIn(
        repayParams.useATokenAsFrom ? collateralATokenAddress : repayParams.collateralAsset,
        repayParams.useATokenAsTo ? debtATokenAddress : repayParams.debtAsset,
        repayParams.debtRepayAmount.add(premium),
        repayParams.useEthPath
      )[0];
      require(amounts0 <= repayParams.collateralAmount, 'slippage too high');
      uint256 feeAmount = amounts0.mul(FEE).div(FEE_DECIMALS);

      if (repayParams.useATokenAsFrom) {
        // Transfer aTokens from user to contract address
        _transferATokenToContractAddress(
          collateralATokenAddress,
          repayParams.user,
          amounts0.add(feeAmount),
          permitSignature
        );
        LENDING_POOL.withdraw(repayParams.collateralAsset, feeAmount, caller);
      } else {
        // Pull aTokens from user
        _pullAToken(
          repayParams.collateralAsset,
          collateralATokenAddress,
          repayParams.user,
          amounts0.add(feeAmount),
          permitSignature
        );
        IERC20(repayParams.collateralAsset).safeTransfer(caller, feeAmount);
      }

      // Swap collateral asset to the debt asset
      _swapTokensForExactTokens(
        repayParams.collateralAsset,
        repayParams.debtAsset,
        repayParams.useATokenAsFrom ? collateralATokenAddress : repayParams.collateralAsset,
        repayParams.useATokenAsTo ? debtATokenAddress : repayParams.debtAsset,
        amounts0,
        repayParams.debtRepayAmount.add(premium),
        repayParams.useEthPath
      );

      if (repayParams.useATokenAsTo) {
        // withdraw debt AToken
        LENDING_POOL.withdraw(
          repayParams.debtAsset,
          IERC20(debtATokenAddress).balanceOf(address(this)),
          address(this)
        );
      }
    } else {
      uint256 feeAmount = repayParams.debtRepayAmount.mul(FEE).div(FEE_DECIMALS);
      // Pull aTokens from user
      _pullAToken(
        repayParams.collateralAsset,
        collateralATokenAddress,
        repayParams.user,
        repayParams.debtRepayAmount.add(premium).add(feeAmount),
        permitSignature
      );
      IERC20(repayParams.collateralAsset).safeTransfer(caller, feeAmount);
    }
  }

  function _decodeParams(bytes memory params)
    internal
    pure
    returns (
      RepayParams memory,
      PermitSignature memory,
      address
    )
  {
    (RepayParams memory repayParams, PermitSignature memory permitSignature, address caller) = abi
      .decode(params, (RepayParams, PermitSignature, address));

    return (repayParams, permitSignature, caller);
  }
}