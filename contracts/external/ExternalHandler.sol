// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../error/Errors.sol";

// contracts with a CONTROLLER role or other roles may need to call external
// contracts, since these roles may be able to directly change DataStore values
// or perform other sensitive operations, these contracts should make these calls
// through ExternalHandler instead
// 具有 CONTROLLER 角色或其他角色的合约可能需要调用外部 合约，
// 因为这些角色可能能够直接更改 DataStore 值 或执行其他敏感操作，
// 因此这些合约应该 通过ExternalHandler 进行这些调用

//
// note 任何人都可以让这个合约调用任何函数，应该注意这一点 
// 以避免在任何协议中假设合约的状态 
// 例如某些代币要求批准金额为零之前 
// 可以更改批准金额，如果这些代币需要调用批准，则应考虑到这一点

contract ExternalHandler is ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;

    function makeExternalCalls(
        address[] memory targets,
        bytes[] memory dataList,
        address[] memory refundTokens,
        address[] memory refundReceivers
    ) external nonReentrant {
        if (targets.length != dataList.length) {
            revert Errors.InvalidExternalCallInput(targets.length, dataList.length);
        }

        if (refundTokens.length != refundReceivers.length) {
            revert Errors.InvalidExternalReceiversInput(refundTokens.length, refundReceivers.length);
        }

        for (uint256 i; i < targets.length; i++) {
            _makeExternalCall(targets[i], dataList[i]);
        }

        for (uint256 i; i < refundTokens.length; i++) {
            IERC20 refundToken = IERC20(refundTokens[i]);
            uint256 balance = refundToken.balanceOf(address(this));
            if (balance > 0) {
                refundToken.safeTransfer(refundReceivers[i], balance);
            }
        }
    }

    function _makeExternalCall(
        address target,
        bytes memory data
    ) internal {
        if (!target.isContract()) {
            revert Errors.InvalidExternalCallTarget(target);
        }

        (bool success, bytes memory returndata) = target.call(data);

        if (!success) {
            revert Errors.ExternalCallFailed(returndata);
        }
    }
}
