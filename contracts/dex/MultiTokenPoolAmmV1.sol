// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./libraries/DexLibrary.sol"; // Importing the utility library
import "@openzeppelin/contracts-upgradeable/utils/cryptography/SignatureCheckerUpgradeable.sol";

import "../../interfaces/IERC20TokenUpgradeable.sol";

contract MultiTokenPoolAmmV1 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20TokenUpgradeable;
    using DexLibrary for uint256;
    using DexLibrary for address;
    using SignatureCheckerUpgradeable for address;
    using ECDSAUpgradeable for bytes32;

    address private safeAddress;
    address public trustedCaller;
    address public kpToken;
    address public tevaToken;
    uint256 public feeNumerator;
    uint256 public feeDenominator;

    struct Pool {
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalLiquidity0;
        uint256 totalLiquidity1;
        uint256 minReserve0;
        uint256 minReserve1;
        bool publicPool;
        bool exists;
    }

    /* Mappings */
    mapping(address account => uint256) private _nonces;
    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => mapping(address => uint256)) public liquidity0;
    mapping(bytes32 => mapping(address => uint256)) public liquidity1;
    mapping(bytes32 => mapping(address => bool)) public whitelist;

    /* Events */
    event LiquidityAdded(
        address indexed provider,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 shares0,
        uint256 shares1
    );
    event LiquidityRemoved(
        address indexed provider,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 shares0,
        uint256 shares1
    );
    event Swap(
        address indexed swapper,
        uint256 indexed nonce,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event WhitelistUpdated(
        address indexed user,
        address tokenA,
        address tokenB,
        bool status
    );

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Teva Dex: EXPIRED");
        _;
    }

    modifier onlyWhitelistedOrOwner(bytes32 poolId) {
        require(
            pools[poolId].publicPool ||
                whitelist[poolId][msg.sender] ||
                msg.sender == owner(),
            "Not whitelisted or owner"
        );
        _;
    }

    function initialize(
        address _tevaToken,
        address _trustedCaller,
        address _kpToken,
        address _safeAddress
    ) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        feeNumerator = 9970; // Initial fee: 0.30%
        feeDenominator = 10000;
        tevaToken = _tevaToken;
        trustedCaller = _trustedCaller;
        kpToken = _kpToken;
        safeAddress = _safeAddress;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function _useNonce(address account) internal virtual returns (uint256) {
        // For each account, the nonce has an initial value of 0, can only be incremented by one, and cannot be
        // decremented or reset. This guarantees that the nonce never overflows.
        unchecked {
            // It is important to do x++ and not ++x here.
            return _nonces[account]++;
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function updateTevaToken(address _tevaToken) external onlyOwner {
        tevaToken = _tevaToken;
    }

    /**
     * @dev Returns a unique pool ID for a pair of tokens.
     * @param tokenA The contract address of the first token.
     * @param tokenB The contract address of the second token.
     * @return The unique bytes32 hash representing the pool ID.
     */
    function getPoolId(
        address tokenA,
        address tokenB
    ) public pure returns (bytes32) {
        return tokenA.getPoolId(tokenB);
    }

    /**
     * @dev Verifies the validity of a signature for the given data and timestamp.
     *
     * This function checks two conditions:
     * 1. Ensures that the provided timestamp is in the future, preventing the acceptance
     *    of expired signatures. If the timestamp is not greater than the current block's
     *    timestamp, the transaction will revert with an "Signature expired" error.
     * 2. Validates the signature against the hashed data. It uses the `recover` function
     *    to check if the signature corresponds to the `trustedCaller` address.
     *    If the recovered address from the signature does not match the `trustedCaller`,
     *    the transaction will revert with an "Invalid signature" error.
     *
     * @param data The original data that was signed.
     * @param timestamp The timestamp to validate that the signature is not expired.
     * @param signature The signature to be verified.
     */
    function verify(
        bytes memory data,
        uint256 timestamp,
        bytes memory signature
    ) internal view {
        require(timestamp > block.timestamp, "Signature expired");
        require(
            keccak256(data).toEthSignedMessageHash().recover(signature) ==
                trustedCaller,
            "Invalid signature"
        );
    }

    /**
     * @dev Updates the minimum required reserves for a pool.
     * @param _poolId The unique bytes32 hash representing the pool ID.
     * @param _minReserve0 The minimum required amount for token0.
     * @param _minReserve1 The minimum required amount for token1.
     */
    function updateMinReserve(
        bytes32 _poolId,
        uint256 _minReserve0,
        uint256 _minReserve1
    ) external onlyOwner {
        Pool storage pool = pools[_poolId];
        require(pool.exists, "Pool doesn't exist");
        pool.minReserve0 = _minReserve0;
        pool.minReserve1 = _minReserve1;
    }

    /**
     * @dev Toggles the public status of a pool.
     * @param _poolId The unique bytes32 hash representing the pool ID.
     * @param newStatus Boolean value indicating whether the pool is public or not.
     */
    function togglePoolPublicStatus(
        bytes32 _poolId,
        bool newStatus
    ) external onlyOwner {
        Pool storage pool = pools[_poolId];
        require(pool.exists, "Pool doesn't exist");
        pool.publicPool = newStatus;
    }

    /**
     * @dev Updates the whitelist status of a user for a specific pool.
     * @param user The address of the user.
     * @param tokenA The contract address of the first token.
     * @param tokenB The contract address of the second token.
     * @param set Boolean value indicating whether to whitelist or remove the user.
     */
    function updateWhitelist(
        address user,
        address tokenA,
        address tokenB,
        bool set
    ) external onlyOwner {
        bytes32 poolId = tokenA.getPoolId(tokenB);
        whitelist[poolId][user] = set;
        emit WhitelistUpdated(user, tokenA, tokenB, set);
    }

    /**
     * @dev Adds liquidity to a pool.
     * @param tokenA The contract address of the first token.
     * @param tokenB The contract address of the second token.
     * @param amountA The amount of token0 to add as liquidity.
     * @param amountB The amount of token1 to add as liquidity.
     * @return shares0 The liquidity shares of token0 allocated to the provider.
     * @return shares1 The liquidity shares of token1 allocated to the provider.
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    )
        external
        nonReentrant
        onlyWhitelistedOrOwner(tokenA.getPoolId(tokenB))
        whenNotPaused
        returns (uint256 shares0, uint256 shares1)
    {
        bytes32 poolId = tokenA.getPoolId(tokenB);
        Pool storage pool = pools[poolId];

        require(
            tokenA == tevaToken || tokenB == tevaToken,
            "One of the token should be Teva!"
        );

        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        (uint256 amount0, uint256 amount1) = tokenA < tokenB
            ? (amountA, amountB)
            : (amountB, amountA);

        // Record the balances of the tokens before transfer
        uint256 balance0Before = IERC20TokenUpgradeable(token0).balanceOf(
            address(this)
        );
        uint256 balance1Before = IERC20TokenUpgradeable(token1).balanceOf(
            address(this)
        );

        // Initialize pool if it doesn't exist
        if (!pool.exists) {
            require(msg.sender == owner(), "Pool does not exist");
            pool.exists = true;
            pool.token0 = token0;
            pool.token1 = token1;
        }

        require(
            amount0 >= pool.minReserve0 && amount0 >= pool.minReserve1,
            "Min reserve not met"
        );

        // Transfer the tokens from the user to the contract
        if (amount0 > 0) {
            IERC20TokenUpgradeable(token0).safeTransferFrom(
                msg.sender,
                address(this),
                amount0
            );
        }
        if (amount1 > 0) {
            IERC20TokenUpgradeable(token1).safeTransferFrom(
                msg.sender,
                address(this),
                amount1
            );
        }

        // Calculate the actual amounts received after the transfer
        uint256 actualAmount0 = IERC20TokenUpgradeable(token0).balanceOf(
            address(this)
        ) - balance0Before;
        uint256 actualAmount1 = IERC20TokenUpgradeable(token1).balanceOf(
            address(this)
        ) - balance1Before;

        // Calculate shares based on actual amounts received
        if (pool.totalLiquidity0 == 0 && pool.totalLiquidity1 == 0) {
            shares0 = DexLibrary.sqrt(actualAmount0 * actualAmount1);
            shares1 = shares0;
        } else {
            shares0 = (actualAmount0 * pool.totalLiquidity0) / pool.reserve0;
            shares1 = (actualAmount1 * pool.totalLiquidity1) / pool.reserve1;
        }

        require(shares0 > 0 || shares1 > 0, "Zero shares issued");

        // Update the pool's reserves and total liquidity
        pool.reserve0 += actualAmount0;
        pool.reserve1 += actualAmount1;
        pool.totalLiquidity0 += shares0;
        pool.totalLiquidity1 += shares1;

        // Update the user's liquidity
        liquidity0[poolId][msg.sender] += shares0;
        liquidity1[poolId][msg.sender] += shares1;

        // Emit the liquidity added event
        emit LiquidityAdded(
            msg.sender,
            token0,
            token1,
            actualAmount0,
            actualAmount1,
            shares0,
            shares1
        );
        return (shares0, shares1);
    }

    /**
     * @dev Removes liquidity from a pool.
     * @param tokenA The contract address of the first token.
     * @param tokenB The contract address of the second token.
     * @param shares0 The number of liquidity shares of token0 to withdraw.
     * @param shares1 The number of liquidity shares of token1 to withdraw.
     * @return amount0 The amount of tokenA withdrawn.
     * @return amount1 The amount of tokenB withdrawn.
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 shares0,
        uint256 shares1
    )
        external
        nonReentrant
        onlyWhitelistedOrOwner(tokenA.getPoolId(tokenB))
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 poolId = tokenA.getPoolId(tokenB);

        (uint256 _shares0, uint256 _shares1) = tokenA < tokenB
            ? (shares0, shares1)
            : (shares1, shares0);

        require(
            (_shares0 > 0 && _shares0 <= liquidity0[poolId][msg.sender]) ||
                (_shares1 > 0 && _shares1 <= liquidity1[poolId][msg.sender]),
            "Invalid share amount"
        );

        Pool storage pool = pools[poolId];
        require(pool.exists, "Pool does not exist");
        require(
            pool.totalLiquidity0 > 0 && pool.totalLiquidity1 > 0,
            "zero liquidity"
        );

        amount0 = (_shares0 * pool.reserve0) / pool.totalLiquidity0;
        amount1 = (_shares1 * pool.reserve1) / pool.totalLiquidity1;

        require(amount0 > 0 || amount1 > 0, "Invalid amounts returned");

        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.totalLiquidity0 -= _shares0;
        pool.totalLiquidity1 -= _shares1;
        liquidity0[poolId][msg.sender] -= _shares0;
        liquidity1[poolId][msg.sender] -= _shares1;

        if (amount0 > 0) {
            IERC20TokenUpgradeable(pool.token0).safeTransfer(
                msg.sender,
                amount0
            );
        }
        if (amount1 > 0) {
            IERC20TokenUpgradeable(pool.token1).safeTransfer(
                msg.sender,
                amount1
            );
        }

        emit LiquidityRemoved(
            msg.sender,
            pool.token0,
            pool.token1,
            amount0,
            amount1,
            _shares0,
            _shares1
        );
        return (amount0, amount1);
    }

    /**
     * @dev Updates the platform fee.
     * @param _newFeeNumerator The new fee numerator.
     * @param _newFeeDenominator The new fee denominator or maximum precision value.
     */
    function updateFee(
        uint256 _newFeeNumerator,
        uint256 _newFeeDenominator
    ) external onlyOwner {
        require(_newFeeNumerator <= _newFeeDenominator, "Invalid fee ratio");
        feeNumerator = _newFeeNumerator;
        feeDenominator = _newFeeDenominator;
    }
    /**
     * @dev Allows owner to update the safe wallet address
     * @param _safeAddress the safe wallet address
     */
    function updateSafeAddress(address _safeAddress) external onlyOwner {
        require(_safeAddress != address(0), "Invalid address!");
        safeAddress = _safeAddress;
    }

    /**
     * @dev Swaps an exact amount of tokens for another token. // Sell KP : Contract recieve KP and User Recieve Teva
     * @param tokenIn The contract address of the input token. //Teva : In and KP : out
     * @param tokenOut The contract address of the output token.
     * @param amountIn The amount of the input token to swap.
     * @param deadline The deadline for the swap.
     * @return amountOut The amount of the output token received for the exact input amount.
     */
    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 deadline,
        bytes calldata _signature
    )
        external
        ensure(deadline)
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut, uint256 platformFee)
    {
        require(amountIn > 0, "Invalid input amount");
        bytes32 poolId = tokenIn.getPoolId(tokenOut);

        Pool storage pool = pools[poolId];
        require(pool.exists, "Pool does not exist");
        (uint256 reserveIn, uint256 reserveOut) = (tokenIn == pool.token0)
            ? (pool.reserve0, pool.reserve1)
            : (pool.reserve1, pool.reserve0);

        (amountOut, platformFee) = amountIn.calculateAmountOut(
            reserveIn,
            reserveOut,
            feeNumerator,
            feeDenominator,
            tokenIn,
            tevaToken
        );
        require(amountOut > 0, "Insufficient output amount");
        if (tokenIn == kpToken || tokenOut == kpToken) {
            settlement(
                tokenIn,
                tokenOut,
                amountIn,
                amountOut,
                deadline,
                _signature
            );
        } else {
            IERC20TokenUpgradeable(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );
            IERC20TokenUpgradeable(tokenOut).safeTransfer(
                msg.sender,
                amountOut
            );
        }
        IERC20TokenUpgradeable(tevaToken).safeTransfer(
            safeAddress,
            platformFee
        );
        
        if (tokenIn == tevaToken) {
            DexLibrary.updateReserves(
                pool,
                tokenIn,
                amountIn - platformFee,
                amountOut
            );
        } else if (tokenOut == tevaToken) {
            DexLibrary.updateReserves(
                pool,
                tokenIn,
                amountIn,
                amountOut + platformFee
            );
        }

        // handle nonce increment if kp token is tokenIn
        uint256 nonceUsed;
        if (tokenIn == kpToken) {
            nonceUsed = _useNonce(msg.sender);
        }
        emit Swap(
            msg.sender,
            nonceUsed,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut
        );
        return (amountOut, platformFee);
    }

    /**
     * @dev Returns the input amount required to get an exact output amount.
     * @param amountOut The exact output amount desired.
     * @param tokenIn The contract address of the input token.
     * @param tokenOut The contract address of the output token.
     * @return amountIn The expected input amount.
     */
    function getAmountIn(
        uint256 amountOut,
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 amountIn) {
        require(amountOut > 0, "Invalid output amount");
        bytes32 poolId = tokenIn.getPoolId(tokenOut);
        Pool storage pool = pools[poolId];
        require(pool.exists, "Pool does not exist");

        (uint256 reserveIn, uint256 reserveOut) = (tokenIn == pool.token0)
            ? (pool.reserve0, pool.reserve1)
            : (pool.reserve1, pool.reserve0);
        (amountIn, ) = amountOut.calculateAmountIn(
            reserveIn,
            reserveOut,
            feeNumerator,
            feeDenominator,
            tokenOut,
            tevaToken
        );
        return amountIn;
    }

    /**
     * @dev Returns the output amount expected for a given input amount.
     * @param tokenIn The contract address of the input token.
     * @param tokenOut The contract address of the output token.
     * @param amountIn The amount of the input token.
     * @return amountOut The expected output amount.
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid input amount");
        bytes32 poolId = tokenIn.getPoolId(tokenOut);
        Pool storage pool = pools[poolId];
        require(pool.exists, "Pool does not exist");

        (uint256 reserveIn, uint256 reserveOut) = (tokenIn == pool.token0)
            ? (pool.reserve0, pool.reserve1)
            : (pool.reserve1, pool.reserve0);
        (amountOut, ) = amountIn.calculateAmountOut(
            reserveIn,
            reserveOut,
            feeNumerator,
            feeDenominator,
            tokenIn,
            tevaToken
        );
        return amountOut;
    }

    function nonces(address account) public view virtual returns (uint256) {
        return _nonces[account];
    }

    function settlement(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 deadline,
        bytes calldata _signature
    ) internal {
        if (address(kpToken) == tokenIn) {
            verify(
                abi.encode(amountIn, msg.sender, _nonces[msg.sender], deadline),
                deadline,
                _signature
            );
            IERC20TokenUpgradeable(kpToken).mint(address(this), amountIn);
            IERC20TokenUpgradeable(tokenOut).safeTransfer(
                msg.sender,
                amountOut
            );
        } else if (address(kpToken) == tokenOut) {
            IERC20TokenUpgradeable(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );
            IERC20TokenUpgradeable(tokenOut).safeTransfer(
                msg.sender,
                amountOut
            );
            IERC20TokenUpgradeable(kpToken).burn(msg.sender, amountOut);
        }
    }

    /**
     * @dev Updates the address of the trusted caller for the contract.
     * This function allows the contract owner to set a new address
     * that will be recognized as the `trustedCaller`, granting it
     * specific privileges or roles defined within the contract logic.
     *
     */
    function updateTrustedCaller(address newTrustedCaller) external onlyOwner {
        require(newTrustedCaller != address(0), "can not address zero");
        trustedCaller = newTrustedCaller;
    }
}
