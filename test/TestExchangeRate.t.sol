// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "chainlink/contracts/src/v0.8/Denominations.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../src/protocol/oracle/PriceOracle.sol";
import "../src/protocol/pool/interest-rate-model/TripleSlopeRateModel.sol";
import "../src/protocol/pool/CreditLimitManager.sol";
import "../src/protocol/pool/IronBank.sol";
import "../src/protocol/pool/IronBankStorage.sol";
import "../src/protocol/pool/MarketConfigurator.sol";
import "../src/protocol/token/IBToken.sol";
import "./Common.t.sol";
import "./MockFeedRegistry.t.sol";

contract ExchangeRateTest is Test, Common {
    uint8 internal constant underlyingDecimals1 = 18; // 1e18
    uint8 internal constant underlyingDecimals2 = 6; // 1e6
    uint8 internal constant underlyingDecimals3 = 18; // 1e18
    uint16 internal constant reserveFactor = 1000; // 10%

    int256 internal constant market1Price = 1500e8;
    int256 internal constant market2Price = 200e8;
    int256 internal constant market3Price = 1500e8;
    uint16 internal constant market1CollateralFactor = 8000; // 80%
    uint16 internal constant market2CollateralFactor = 8000; // 80%

    IronBank ib;
    MarketConfigurator configurator;
    CreditLimitManager creditLimitManager;
    FeedRegistry registry;
    PriceOracle oracle;

    ERC20Market market1; // decimals: 18, reserve factor: 10%, price: 1500
    ERC20Market market2; // decimals: 6, reserve factor: 10%, price: 200
    ERC20Market market3; // decimals: 18, reserve factor: 0%, price: 1500
    IBToken ibToken1;
    IBToken ibToken2;
    IBToken ibToken3;

    address admin = address(64);
    address user1 = address(128);

    function setUp() public {
        ib = createIronBank(admin);

        configurator = createMarketConfigurator(admin, ib);
        ib.setMarketConfigurator(address(configurator));

        creditLimitManager = createCreditLimitManager(admin, ib);
        ib.setCreditLimitManager(address(creditLimitManager));

        TripleSlopeRateModel irm = createDefaultIRM();

        (market1, ibToken1,) =
            createAndListERC20Market(underlyingDecimals1, admin, ib, configurator, irm, reserveFactor);
        (market2, ibToken2,) =
            createAndListERC20Market(underlyingDecimals2, admin, ib, configurator, irm, reserveFactor);
        (market3, ibToken3,) = createAndListERC20Market(underlyingDecimals3, admin, ib, configurator, irm, 0);

        registry = createRegistry();
        oracle = createPriceOracle(admin, address(registry));
        ib.setPriceOracle(address(oracle));

        setPriceForMarket(oracle, registry, admin, address(market1), address(market1), Denominations.USD, market1Price);
        setPriceForMarket(oracle, registry, admin, address(market2), address(market2), Denominations.USD, market2Price);
        setPriceForMarket(oracle, registry, admin, address(market3), address(market3), Denominations.USD, market3Price);

        setMarketCollateralFactor(admin, configurator, address(market1), market1CollateralFactor);
        setMarketCollateralFactor(admin, configurator, address(market2), market2CollateralFactor);

        vm.startPrank(admin);
        market1.transfer(user1, 10_000 * (10 ** underlyingDecimals1));
        market2.transfer(user1, 10_000 * (10 ** underlyingDecimals2));
        market3.transfer(user1, 10_000 * (10 ** underlyingDecimals3));
        vm.stopPrank();
    }

    function testExchangeRate1e6SupplyAndBorrow() public {
        // Admin provides market2 liquidity and user1 borrows market2 against market1.

        uint256 market1SupplyAmount = 100 * (10 ** underlyingDecimals1);
        uint256 market2BorrowAmount = 300 * (10 ** underlyingDecimals2);
        uint256 market2SupplyAmount = 500 * (10 ** underlyingDecimals2);

        vm.startPrank(admin);
        market2.approve(address(ib), market2SupplyAmount);
        ib.supply(admin, address(market2), market2SupplyAmount);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market2)), 10 ** underlyingDecimals2);

        vm.startPrank(user1);
        market1.approve(address(ib), market1SupplyAmount);
        ib.supply(user1, address(market1), market1SupplyAmount);
        ib.enterMarket(user1, address(market1));
        ib.borrow(user1, address(market2), market2BorrowAmount);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market2)), 10 ** underlyingDecimals2);

        fastForwardTime(86400);

        /**
         * utilization = 300 / 500 = 60% < kink1 = 80%
         * borrow rate = 0.000000001 + 0.6 * 0.000000001 = 0.0000000016
         * borrow interest = 0.0000000016 * 86400 * 300 = 0.041472
         * fee increased = 0.041472 * 0.1 = 0.004147 (truncated)
         *
         * new total borrow = 300.041472
         * new total supply = 500 * 500.041472 / (500.041472 - 0.004147) = 500.004146690449557940
         * new total reserves = 500.004146690449557940 - 500 = 0.004146690449557940
         * new exchange rate = 500.041472 / 500.004146690449557940 = 1.000074
         */
        ib.accrueInterest(address(market2));
        assertEq(ib.getExchangeRate(address(market2)), 1.000074e6);

        (uint256 totalCash, uint256 totalBorrow, uint256 totalSupply,, uint256 totalReserves) =
            ib.getMarketStatus(address(market2));
        assertEq(totalCash, 200e6);
        assertEq(totalBorrow, 300.041472e6);
        assertEq(totalSupply, 500.00414669044955794e18);
        assertEq(totalReserves, 0.00414669044955794e18);

        // Now market2 exchange rate is larger than 1. Repay the debt and redeem all to see how the exchange rate changes.

        vm.startPrank(user1);
        market2.approve(address(ib), type(uint256).max);
        ib.repay(user1, address(market2), type(uint256).max);
        vm.stopPrank();

        vm.prank(admin);
        ib.redeem(admin, address(market2), type(uint256).max);

        /**
         * admin market2 amount = 500 * 1.000074 = 500.037
         * total cash = 500.041472 - 500.037 = 0.004472
         * total borrow = 0
         * total supply = 500.004146690449557940 - 500 = 0.004146690449557940
         * total reserve = 0.004146690449557940
         * new exchange rate = 0.004472 / 0.004146690449557940 = 1.078450
         *
         * (In this case, the exchange rate will grow quite a lot when the market decimals is much smaller than 1e18.)
         */
        assertEq(ib.getExchangeRate(address(market2)), 1.07845e6);

        (totalCash, totalBorrow, totalSupply,, totalReserves) = ib.getMarketStatus(address(market2));
        assertEq(totalCash, 0.004472e6);
        assertEq(totalBorrow, 0);
        assertEq(totalSupply, 0.00414669044955794e18);
        assertEq(totalReserves, 0.00414669044955794e18);
    }

    function testExchangeRate1e18SupplyAndRedeem() public {
        // In compound v2, cToken decimal is 8, if the underlying token decimal is larger than 8,
        // it could make the exchange rate smaller when the total supply is extremely small.
        // Here, we limit the market decimal to be smaller or equal to 18 and ibToken decimal to 18, so we're good.
        uint256 supplyAmount = 100.123123123123123123e18;
        uint256 redeemAmount = supplyAmount - 1;

        vm.startPrank(user1);
        market1.approve(address(ib), supplyAmount);
        ib.supply(user1, address(market1), supplyAmount);
        ib.redeem(user1, address(market1), redeemAmount);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market1)), 10 ** underlyingDecimals1);

        (uint256 totalCash, uint256 totalBorrow, uint256 totalSupply,,) = ib.getMarketStatus(address(market1));
        assertEq(totalCash, 1);
        assertEq(totalBorrow, 0);
        assertEq(totalSupply, 1);
    }

    function testExchangeRate1e18SupplyAndRedeem2() public {
        // Admin provides market1 liquidity and user1 borrows market1 against market2.
        // After 1 day, user1 repays the debt and makes market1 exchange rate larger than 1.
        uint256 market2SupplyAmount = 3000 * (10 ** underlyingDecimals2);
        uint256 market1BorrowAmount = 300 * (10 ** underlyingDecimals1);
        uint256 market1SupplyAmount = 500 * (10 ** underlyingDecimals1);

        vm.startPrank(admin);
        market1.approve(address(ib), market1SupplyAmount);
        ib.supply(admin, address(market1), market1SupplyAmount);
        vm.stopPrank();

        vm.startPrank(user1);
        market2.approve(address(ib), market2SupplyAmount);
        ib.supply(user1, address(market2), market2SupplyAmount);
        ib.enterMarket(user1, address(market2));
        ib.borrow(user1, address(market1), market1BorrowAmount);

        fastForwardTime(86400);

        market1.approve(address(ib), type(uint256).max);
        ib.repay(user1, address(market1), type(uint256).max);
        vm.stopPrank();

        uint256 exchangeRate = ib.getExchangeRate(address(market1));
        assertTrue(exchangeRate > 1e18);

        // Now market1 exchange rate is larger than 1. Test user1 supplies and redeems the same amount.

        uint256 supplyAmount = 100.123123123123123123e18;

        vm.startPrank(user1);
        market1.approve(address(ib), supplyAmount);
        ib.supply(user1, address(market1), supplyAmount);
        ib.redeem(user1, address(market1), type(uint256).max);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market1)), exchangeRate); // exchange rate won't change
        assertEq(ibToken1.balanceOf(user1), 0);
    }

    function testExchangeRate1e18SupplyAndBorrow() public {
        // Admin provides market1 liquidity and user1 borrows market1 against market2.

        uint256 market2SupplyAmount = 3000 * (10 ** underlyingDecimals2);
        uint256 market1BorrowAmount = 300 * (10 ** underlyingDecimals1);
        uint256 market1SupplyAmount = 500 * (10 ** underlyingDecimals1);

        vm.startPrank(admin);
        market1.approve(address(ib), market1SupplyAmount);
        ib.supply(admin, address(market1), market1SupplyAmount);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market1)), 10 ** underlyingDecimals1);

        vm.startPrank(user1);
        market2.approve(address(ib), market2SupplyAmount);
        ib.supply(user1, address(market2), market2SupplyAmount);
        ib.enterMarket(user1, address(market2));
        ib.borrow(user1, address(market1), market1BorrowAmount);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market1)), 10 ** underlyingDecimals1);

        fastForwardTime(86400);

        /**
         * utilization = 300 / 500 = 60% < kink1 = 80%
         * borrow rate = 0.000000001 + 0.6 * 0.000000001 = 0.0000000016
         * borrow interest = 0.0000000016 * 86400 * 300 = 0.041472
         * fee increased = 0.041472 * 0.1 = 0.0041472
         *
         * new total borrow = 300.041472
         * new total supply = 500 * 500.041472 / (500.041472 - 0.0041472) = 500.004146890436287687
         * new total reserves = 500.004146890436287687 - 500 = 0.004146890436287687
         * new exchange rate = 500.041472 / 500.004146890436287687 = 1.0000746496
         */
        ib.accrueInterest(address(market1));
        assertEq(ib.getExchangeRate(address(market1)), 1.0000746496e18);

        (uint256 totalCash, uint256 totalBorrow, uint256 totalSupply,, uint256 totalReserves) =
            ib.getMarketStatus(address(market1));
        assertEq(totalCash, 200e18);
        assertEq(totalBorrow, 300.041472e18);
        assertEq(totalSupply, 500.004146890436287687e18);
        assertEq(totalReserves, 0.004146890436287687e18);

        // Now market1 exchange rate is larger than 1. Repay the debt and redeem all to see how the exchange rate changes.

        vm.startPrank(user1);
        market1.approve(address(ib), type(uint256).max);
        ib.repay(user1, address(market1), type(uint256).max);
        vm.stopPrank();

        vm.prank(admin);
        ib.redeem(admin, address(market1), type(uint256).max);

        /**
         * admin market1 amount = 500 * 1.0000746496 = 500.0373248
         * total cash = 500.041472 - 500.0373248 = 0.0041472
         * total borrow = 0
         * total supply = 500.004146890436287687 - 500 = 0.004146890436287687
         * total reserve = 0.004146890436287687
         * new exchange rate = 0.0041472 / 0.004146890436287687 = 1.000074649600000072
         */
        assertEq(ib.getExchangeRate(address(market1)), 1.000074649600000072e18);

        (totalCash, totalBorrow, totalSupply,, totalReserves) = ib.getMarketStatus(address(market1));
        assertEq(totalCash, 0.0041472e18);
        assertEq(totalBorrow, 0);
        assertEq(totalSupply, 0.004146890436287687e18);
        assertEq(totalReserves, 0.004146890436287687e18);
    }

    function testExchangeRate1e18SupplyAndBorrowNoReserve() public {
        // Admin provides market3 liquidity and user1 borrows market3 against market2.

        uint256 market2SupplyAmount = 3000 * (10 ** underlyingDecimals2);
        uint256 market3BorrowAmount = 300 * (10 ** underlyingDecimals3);
        uint256 market3SupplyAmount = 500 * (10 ** underlyingDecimals3);

        vm.startPrank(admin);
        market3.approve(address(ib), market3SupplyAmount);
        ib.supply(admin, address(market3), market3SupplyAmount);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market3)), 10 ** underlyingDecimals3);

        vm.startPrank(user1);
        market2.approve(address(ib), market2SupplyAmount);
        ib.supply(user1, address(market2), market2SupplyAmount);
        ib.enterMarket(user1, address(market2));
        ib.borrow(user1, address(market3), market3BorrowAmount);
        vm.stopPrank();

        assertEq(ib.getExchangeRate(address(market3)), 10 ** underlyingDecimals3);

        fastForwardTime(86400);

        /**
         * utilization = 300 / 500 = 60% < kink1 = 80%
         * borrow rate = 0.000000001 + 0.6 * 0.000000001 = 0.0000000016
         * borrow interest = 0.0000000016 * 86400 * 300 = 0.041472
         *
         * new total borrow = 300.041472
         * new total supply = 500
         * new exchange rate = 500.041472 / 500 = 1.000082944
         */
        ib.accrueInterest(address(market3));
        assertEq(ib.getExchangeRate(address(market3)), 1.000082944e18);

        (uint256 totalCash, uint256 totalBorrow, uint256 totalSupply,, uint256 totalReserves) =
            ib.getMarketStatus(address(market3));
        assertEq(totalCash, 200e18);
        assertEq(totalBorrow, 300.041472e18);
        assertEq(totalSupply, 500e18);
        assertEq(totalReserves, 0);

        // Now market3 exchange rate is larger than 1. Repay the debt and redeem all to see how the exchange rate changes.

        vm.startPrank(user1);
        market3.approve(address(ib), type(uint256).max);
        ib.repay(user1, address(market3), type(uint256).max);
        vm.stopPrank();

        vm.prank(admin);
        ib.redeem(admin, address(market3), type(uint256).max);

        /**
         * admin market3 amount = 500 * 1.000082944 = 500.041472
         * total cash = 500.041472 - 500.041472 = 0
         * total borrow = 0
         * total supply = 500 - 500 = 0
         * new exchange rate = 1
         */
        assertEq(ib.getExchangeRate(address(market3)), 1e18);

        (totalCash, totalBorrow, totalSupply,, totalReserves) = ib.getMarketStatus(address(market3));
        assertEq(totalCash, 0);
        assertEq(totalBorrow, 0);
        assertEq(totalSupply, 0);
        assertEq(totalReserves, 0);
    }
}
