// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol"; 
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract ArbitrageBot is Ownable, ReentrancyGuard {
    // Hardcoded addresses for testing on Sepolia
    address public immutable WETH = 0x5f207d42F869fd1c71d7f0f81a2A67Fc20FF7323;
    address public immutable routerA = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address public immutable routerB = 0xeaBcE3E74EF41FB40024a21Cc2ee2F5dDc615791;
    address public immutable token = 0x042118513fE242560c13013B4D31e88329237878; // MockUSDT

    // Pass initial owner to Ownable constructor
    constructor(address initialOwner) Ownable(initialOwner) {}

    function executeArbitrage(uint256 amount) external nonReentrant onlyOwner {
        require(amount > 0, "Amount must be greater than zero");

        // Approve both routers to spend the token
        IERC20(token).approve(routerA, amount);
        IERC20(token).approve(routerB, amount);

        // Build swap path for routerA: token -> WETH
        address[] memory pathA = new address[](2);
        pathA[0] = token;
        pathA[1] = WETH;
        
        // Build reverse path for routerB: WETH -> token
        address[] memory pathB = new address[](2);
        pathB[0] = WETH;
        pathB[1] = token;

        // Perform swap on routerA: token -> WETH
        uint256[] memory amountsOutA = IUniswapV2Router02(routerA).swapExactTokensForTokens(
            amount,
            1, // minimum amount out (for testing; adjust for production)
            pathA,
            address(this),
            block.timestamp + 300
        );
        uint256 amountReceived = amountsOutA[1];

        // Perform swap on routerB: WETH -> token
        uint256[] memory amountsOutB = IUniswapV2Router02(routerB).swapExactTokensForTokens(
            amountReceived,
            1, // minimum amount out (for testing)
            pathB,
            address(this),
            block.timestamp + 300
        );
        uint256 finalAmount = amountsOutB[1];

        require(finalAmount > amount, "Arbitrage failed: No profit");
    }

    function withdrawFunds() external onlyOwner nonReentrant returns (bool) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No funds to withdraw");
        require(IERC20(token).transfer(owner(), balance), "Transfer failed");
        return true;
    }
}
