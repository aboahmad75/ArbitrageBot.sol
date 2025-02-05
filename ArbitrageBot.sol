// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory);
}

// Minimal interface for WETH unwrapping
interface IWETH {
    function withdraw(uint256 amount) external;
}

contract ArbitrageBot is ReentrancyGuard {
    address public owner;
    // Set WETH address for Sepolia (ensure this is correct for your network)
    address public WETH = 0x5f207d42F869fd1c71d7f0f81a2A67Fc20FF7323;
    // DEX Router addresses on Sepolia
    address public routerA = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address public routerB = 0xeaBcE3E74EF41FB40024a21Cc2ee2F5dDc615791;
    uint256 public tradingAmount = 0.05 ether; // Default trading amount: 0.05 ETH (in WETH)\n    uint256 public slippageTolerance = 2; // 2% default slippage\n    uint256 public maxLossThreshold = 0.05 ether; // Stop trades if losses exceed threshold\n    bool public circuitBreaker = false; // Emergency stop switch\n\n    event ArbitrageExecuted(address token, uint256 profit);\n    event Withdraw(address token, uint256 amount);\n    event CircuitBreakerTriggered(bool status);\n    event TradeFailure(string reason);\n\n    modifier onlyOwner() {\n        require(msg.sender == owner, \"Only owner can call this function\");\n        _;\n    }\n\n    modifier tradingAllowed() {\n        require(!circuitBreaker, \"Trading is paused by circuit breaker\");\n        _;\n    }\n\n    constructor() {\n        owner = msg.sender;\n    }\n\n    function setTradingAmount(uint256 amount) external onlyOwner {\n        require(amount > 0, \"Trading amount must be greater than zero\");\n        tradingAmount = amount;\n    }\n\n    function updateRouters(address _routerA, address _routerB) external onlyOwner {\n        require(_routerA != address(0) && _routerB != address(0), \"Invalid router addresses\");\n        routerA = _routerA;\n        routerB = _routerB;\n    }\n\n    function setSlippageTolerance(uint256 _slippage) external onlyOwner {\n        require(_slippage <= 10, \"Slippage too high\");\n        slippageTolerance = _slippage;\n    }\n\n    function setMaxLossThreshold(uint256 _threshold) external onlyOwner {\n        require(_threshold > 0, \"Threshold must be greater than zero\");\n        maxLossThreshold = _threshold;\n    }\n\n    function toggleCircuitBreaker(bool _status) external onlyOwner {\n        circuitBreaker = _status;\n        emit CircuitBreakerTriggered(_status);\n    }\n\n    // Check arbitrage opportunity for a given token swap path\n    // Example path: [WETH, USDT]\n    function checkArbitrage(address[] memory path) public view returns (bool, uint256) {\n        require(path.length >= 2, \"Invalid path length\");\n        uint256 balance = IERC20(path[0]).balanceOf(address(this));\n        if (balance < tradingAmount) {\n            return (false, 0);\n        }\n        uint256 amountOutA = IRouter(routerA).getAmountsOut(tradingAmount, path)[1];\n        uint256 amountOutB = IRouter(routerB).getAmountsOut(tradingAmount, path)[1];\n        if (amountOutA > amountOutB) {\n            return (true, amountOutA - amountOutB);\n        }\n        return (false, 0);\n    }\n\n    // Approve tokens if allowance is insufficient\n    function approveTokens(address token, address spender, uint256 amount) internal {\n        if (IERC20(token).allowance(address(this), spender) < amount) {\n            require(IERC20(token).approve(spender, amount), \"Token approval failed\");\n        }\n    }\n\n    // Execute arbitrage using a provided token swap path\n    // Example path: [WETH, USDT]\n    function executeArbitrage(address[] calldata path) \n        external \n        onlyOwner \n        nonReentrant \n        tradingAllowed \n    {\n        require(path.length >= 2, \"Invalid path length\");\n        (bool profitable, uint256 profit) = checkArbitrage(path);\n        require(profitable, \"No arbitrage opportunity\");\n        require(profit > maxLossThreshold, \"Trade loss exceeds threshold\");\n\n        approveTokens(path[0], routerA, tradingAmount);\n\n        try IRouter(routerA).swapExactTokensForTokens(\n            tradingAmount,\n            (profit * (100 - slippageTolerance)) / 100, // Apply slippage tolerance\n            path,\n            address(this),\n            block.timestamp\n        ) returns (uint256[] memory amountsOutA) {\n            address[] memory reversePath = new address[](2);\n            reversePath[0] = path[path.length - 1];\n            reversePath[1] = path[0];\n\n            approveTokens(reversePath[0], routerB, amountsOutA[1]);\n\n            try IRouter(routerB).swapExactTokensForTokens(\n                amountsOutA[1],\n                (amountsOutA[1] * (100 - slippageTolerance)) / 100,\n                reversePath,\n                address(this),\n                block.timestamp\n            ) returns (uint256[] memory amountsOutB) {\n                require(amountsOutB[1] >= tradingAmount, \"Trade did not yield expected returns\");\n                emit ArbitrageExecuted(path[0], profit);\n            } catch {\n                emit TradeFailure(\"Trade failed on router B\");\n                revert(\"Trade failed on router B\");\n            }\n        } catch {\n            emit TradeFailure(\"Trade failed on router A\");\n            revert(\"Trade failed on router A\");\n        }\n    }\n\n    // Withdraw all tokens from the contract. If withdrawing WETH, it will unwrap to ETH and send ETH to owner.\n    function withdrawAll(address _token) public onlyOwner nonReentrant returns (bool) {\n        require(_token != address(0), \"Token cannot be zero address\");\n        uint256 balance = IERC20(_token).balanceOf(address(this));\n        require(balance > 0, \"No funds to withdraw\");\n        \n        if (_token == WETH) {\n            // Unwrap WETH to ETH before withdrawing\n            IWETH(WETH).withdraw(balance);\n            (bool success, ) = payable(owner).call{value: balance}(\"\");\n            require(success, \"ETH transfer failed\");\n        } else {\n            require(IERC20(_token).transfer(owner, balance), \"Transfer failed\");\n        }\n        emit Withdraw(_token, balance);\n        return true;\n    }\n\n    // Allow the contract to receive ETH (for unwrapping WETH)\n    receive() external payable {}\n}\n\n// Minimal interface for WETH to allow unwrapping\ninterface IWETH {\n    function withdraw(uint256 amount) external;\n}\n```
