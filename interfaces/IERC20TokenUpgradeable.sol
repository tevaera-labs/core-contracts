// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IERC20TokenUpgradeable is IERC20Upgradeable {
    function mint(
        address to,
        uint256 amount
    ) external;

    function burn(
        address from, 
        uint256 amount
    ) external; 

}