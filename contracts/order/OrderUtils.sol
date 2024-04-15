// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../data/Keys.sol";

import "./Order.sol";
import "./OrderVault.sol";
import "./OrderStoreUtils.sol";
import "./OrderEventUtils.sol";

import "../nonce/NonceUtils.sol";
import "../oracle/Oracle.sol";
import "../oracle/OracleUtils.sol";
import "../event/EventEmitter.sol";

import "./IncreaseOrderUtils.sol";
import "./DecreaseOrderUtils.sol";
import "./SwapOrderUtils.sol";
import "./BaseOrderUtils.sol";

import "../swap/SwapUtils.sol";

import "../gas/GasUtils.sol";
import "../callback/CallbackUtils.sol";

import "../utils/Array.sol";
import "../utils/AccountUtils.sol";
import "../referral/ReferralUtils.sol";

import "../token/TokenUtils.sol";

// @title OrderUtils
// @dev Library for order functions
library OrderUtils {
    using Order for Order.Props;
    using Position for Position.Props;
    using Price for Price.Props;
    using Array for uint256[];

    // @dev creates an order in the order store
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param account the order account
    // @param params IBaseOrderUtils.CreateOrderParams
    function createOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        IReferralStorage referralStorage,
        address account,
        IBaseOrderUtils.CreateOrderParams memory params
    ) external returns (bytes32) {
        AccountUtils.validateAccount(account);

        ReferralUtils.setTraderReferralCode(referralStorage, account, params.referralCode);

        uint256 initialCollateralDeltaAmount;

        address wnt = TokenUtils.wnt(dataStore);

        bool isWNT = false;

        if (
            params.orderType == Order.OrderType.MarketSwap ||
            params.orderType == Order.OrderType.LimitSwap ||
            params.orderType == Order.OrderType.MarketIncrease ||
            params.orderType == Order.OrderType.LimitIncrease
        ) {
            // for swaps and increase orders, 
            // the initialCollateralDeltaAmount is set based on the amount of tokens transferred to the orderVault
            initialCollateralDeltaAmount = orderVault.recordTransferIn(params.addresses.initialCollateralToken);

            // 如果是 wnt ,扣除 执行费
            if (params.addresses.initialCollateralToken == wnt) {
                if (initialCollateralDeltaAmount < params.numbers.executionFee) {
                    revert Errors.InsufficientWntAmountForExecutionFee(initialCollateralDeltaAmount, params.numbers.executionFee);
                }
                initialCollateralDeltaAmount -= params.numbers.executionFee;
                
                // 应单独记录 执行费 转账
                isWNT = true;
            }
        } else if (
            params.orderType == Order.OrderType.MarketDecrease ||
            params.orderType == Order.OrderType.LimitDecrease ||
            params.orderType == Order.OrderType.StopLossDecrease
        ) {
            // for decrease orders, the initialCollateralDeltaAmount is based on the passed in value
            initialCollateralDeltaAmount = params.numbers.initialCollateralDeltaAmount;
        } else {
            revert Errors.OrderTypeCannotBeCreated(uint256(params.orderType));
        }

        if (!isWNT) {
            
            uint256 wntAmount = orderVault.recordTransferIn(wnt);

            if (wntAmount < params.numbers.executionFee) {
                revert Errors.InsufficientWntAmountForExecutionFee(wntAmount, params.numbers.executionFee);
            }

            params.numbers.executionFee = wntAmount;
        }

        if (BaseOrderUtils.isPositionOrder(params.orderType)) {
            MarketUtils.validatePositionMarket(dataStore, params.addresses.market);
        }

        // validate swap path markets
        MarketUtils.validateSwapPath(dataStore, params.addresses.swapPath);

        Order.Props memory order;

        order.setAccount(account);
        order.setReceiver(params.addresses.receiver);
        order.setCallbackContract(params.addresses.callbackContract);
        order.setMarket(params.addresses.market);
        order.setInitialCollateralToken(params.addresses.initialCollateralToken);
        order.setUiFeeReceiver(params.addresses.uiFeeReceiver);
        order.setSwapPath(params.addresses.swapPath);
        order.setOrderType(params.orderType);
        order.setDecreasePositionSwapType(params.decreasePositionSwapType);
        order.setSizeDeltaUsd(params.numbers.sizeDeltaUsd);
        order.setInitialCollateralDeltaAmount(initialCollateralDeltaAmount);
        order.setTriggerPrice(params.numbers.triggerPrice);
        order.setAcceptablePrice(params.numbers.acceptablePrice);
        order.setExecutionFee(params.numbers.executionFee);
        order.setCallbackGasLimit(params.numbers.callbackGasLimit);
        order.setMinOutputAmount(params.numbers.minOutputAmount);
        order.setIsLong(params.isLong);
        order.setShouldUnwrapNativeToken(params.shouldUnwrapNativeToken);
        order.touch();  // setUpdatedAtBlock


        // 验证 接受者
        AccountUtils.validateReceiver(order.receiver());

        // 验证 CallbackGasLimit
        CallbackUtils.validateCallbackGasLimit(dataStore, order.callbackGasLimit());

        uint256 estimatedGasLimit = GasUtils.estimateExecuteOrderGasLimit(dataStore, order);
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, order.executionFee());

        bytes32 key = NonceUtils.getNextKey(dataStore);

        // 验证非零订单
        BaseOrderUtils.validateNonEmptyOrder(order);

        // 存储订单
        OrderStoreUtils.set(dataStore, key, order);

        // 触发事件
        OrderEventUtils.emitOrderCreated(eventEmitter, key, order);

        return key;
    }

    // @dev executes an order
    // @param params BaseOrderUtils.ExecuteOrderParams
    function executeOrder(
        BaseOrderUtils.ExecuteOrderParams memory params
    ) external {

        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        //  63/64  转发到外部调用，减少startingGas来解决这个问题
        params.startingGas -= gasleft() / 63;

        OrderStoreUtils.remove(params.contracts.dataStore, params.key, params.order.account());

        // 校验订单
        BaseOrderUtils.validateNonEmptyOrder(params.order);

        // 校验触发价格
        BaseOrderUtils.validateOrderTriggerPrice(
            params.contracts.oracle,
            params.market.indexToken,
            params.order.orderType(),
            params.order.triggerPrice(),
            params.order.isLong()
        );

        // 处理订单
        EventUtils.EventLogData memory eventData = processOrder(params);

        // validate that internal state changes are correct before calling external callbacks
        // if the native token was transferred to the receiver in a swap
        // it may be possible to invoke external contracts before the validations are called
        // 在 calling external callbacks 之前 验证内部状态更改是否正确
        // 如果 native token 在 swap 中转移到接收者 
        // 则可以在调用验证之前调用外部合约 
        //
        if (params.market.marketToken != address(0)) {
            MarketUtils.validateMarketTokenBalance(params.contracts.dataStore, params.market);
        }

        MarketUtils.validateMarketTokenBalance(params.contracts.dataStore, params.swapPathMarkets);

        // 触发事件
        OrderEventUtils.emitOrderExecuted(
            params.contracts.eventEmitter,
            params.key,
            params.order.account(),
            params.secondaryOrderType
        );


        // 执行后 回调
        CallbackUtils.afterOrderExecution(params.key, params.order, eventData);
        
        // the order.executionFee for liquidation / adl orders is zero
        // gas costs for liquidations / adl is subsidised by the treasury

        // 给 Keper 的费用
        // liquidation / adl 订单 的 gas fee 为0，费用由 treasury 补贴
        GasUtils.payExecutionFee(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.contracts.orderVault,
            params.order.executionFee(),
            params.startingGas,
            params.keeper,
            params.order.account()
        );
        
    }

    // 处理订单执行
    // @dev process an order execution
    // @param params BaseOrderUtils.ExecuteOrderParams
    function processOrder(BaseOrderUtils.ExecuteOrderParams memory params)
        internal 
        returns (EventUtils.EventLogData memory) 
    {
        if (BaseOrderUtils.isIncreaseOrder(params.order.orderType())) {
            return IncreaseOrderUtils.processOrder(params);
        }

        if (BaseOrderUtils.isDecreaseOrder(params.order.orderType())) {
            return DecreaseOrderUtils.processOrder(params);
        }

        // if (BaseOrderUtils.isSwapOrder(params.order.orderType())) {
        //     return SwapOrderUtils.processOrder(params);
        // }

        revert Errors.UnsupportedOrderType();
    }

    // @dev cancels an order
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param key the key of the order to cancel
    // @param keeper the keeper sending the transaction
    // @param startingGas the starting gas of the transaction
    // @param reason the reason for cancellation
    function cancelOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        startingGas -= gasleft() / 63;

        Order.Props memory order = OrderStoreUtils.get(dataStore, key);
        BaseOrderUtils.validateNonEmptyOrder(order);

        OrderStoreUtils.remove(dataStore, key, order.account());


        if (
            BaseOrderUtils.isIncreaseOrder(order.orderType()) ||    // IncreaseOrder
            BaseOrderUtils.isSwapOrder(order.orderType())           // SwapOrder
        ) {
            if (order.initialCollateralDeltaAmount() > 0) {         // 初始抵押品 增量金额 
                
                orderVault.transferOut(
                    order.initialCollateralToken(),         // 抵押代币种类
                    order.account(),                        // 账户地址
                    order.initialCollateralDeltaAmount(),   // 抵押代币额
                    order.shouldUnwrapNativeToken()         // 是否 UnwrapNativeToken
                );

            }
        }

        // 触发事件
        OrderEventUtils.emitOrderCancelled(
            eventEmitter,
            key,
            order.account(),
            reason,
            reasonBytes
        );

        // 
        EventUtils.EventLogData memory eventData;
        CallbackUtils.afterOrderCancellation(key, order, eventData);

        GasUtils.payExecutionFee(
            dataStore,
            eventEmitter,
            orderVault,
            order.executionFee(),
            startingGas,
            keeper,
            order.account()
        );
    }

    // @dev freezes an order
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param key the key of the order to freeze
    // @param keeper the keeper sending the transaction
    // @param startingGas the starting gas of the transaction
    // @param reason the reason the order was frozen
    function freezeOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        startingGas -= gasleft() / 63;

        Order.Props memory order = OrderStoreUtils.get(dataStore, key);
        BaseOrderUtils.validateNonEmptyOrder(order);

        if (order.isFrozen()) {
            revert Errors.OrderAlreadyFrozen();
        }

        uint256 executionFee = order.executionFee();

        order.setExecutionFee(0);
        order.setIsFrozen(true);
        OrderStoreUtils.set(dataStore, key, order);

        OrderEventUtils.emitOrderFrozen(
            eventEmitter,
            key,
            order.account(),
            reason,
            reasonBytes
        );

        EventUtils.EventLogData memory eventData;
        CallbackUtils.afterOrderFrozen(key, order, eventData);

        GasUtils.payExecutionFee(
            dataStore,
            eventEmitter,
            orderVault,
            executionFee,
            startingGas,
            keeper,
            order.account()
        );
    }
}
