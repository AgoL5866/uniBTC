// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../../../../interfaces/IMintableContract.sol";
import "../../../../interfaces/IVault.sol";

contract DelayRedeemRouter is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /**
     * @notice The duration of one day in seconds (60 * 60 * 24 = 86,400)
     */
    uint256 public constant SECONDS_IN_A_DAY = 86400;

    /**
     * @notice The duration time set to 30 days (60 * 60 * 24 * 30 = 2,592,000).
     */
    uint256 public constant MAX_REDEEM_DELAY = 2592000;

    /**
     * @notice The maximum amount of uniBTC that can be burned in a single day for each specific BTC token.
     */
    uint256 public constant MAX_DAILY_REDEEM_CAP = 100e8;

    /**
     * @notice Defines the redeem fee rate range, with precision to ten-thousandths.
     */
    uint256 public constant REDEEM_FEE_RATE_RANGE = 10000;

    /**
     * @notice Default redeem fee rate (2%).
     */
    uint256 public constant DEFAULT_REDEEM_FEE_RATE = 200;

    /**
     * @notice Delay for completing any delayed redeem, measured in timestamps.
     * Adjustable by the contract owner, with a maximum limit of `MAX_REDEEM_DELAY`.
     * The minimum value is 0 (i.e., no enforced delay).
     */
    uint256 public redeemDelay;

    /**
     * @notice The address of the ERC20 uniBTC token.
     */
    address public uniBTC;

    /**
     * @notice The address of the Vault contract.
     */
    address public vault;

    /**
     * @notice Struct for storing delayed redeem information.
     * @param amount The amount of the delayed redeem for a specific BTC token.
     * @param createdAt The timestamp at which the `DelayedRedeem` was created.
     * @param token The address of a specific BTC token.
     */
    struct DelayedRedeem {
        uint224 amount;
        uint32 createdAt;
        address token;
    }

    /**
     * @notice Struct for storing a user's delayed redeem data.
     * @param delayedRedeemsCompleted The number of delayed redeems that have been completed.
     * @param delayedRedeems An array of delayed redeems.
     */
    struct UserDelayedRedeems {
        uint256 delayedRedeemsCompleted;
        DelayedRedeem[] delayedRedeems;
    }

    /**
     * @notice Struct for temporarily storing a debt BTC token type and corresponding cumulative amounts.
     * @param token The address of a specific BTC token.
     * @param amount The redeem amount of a specific BTC token.
     */
    struct DebtTokenAmount {
        address token;
        uint256 amount;
        uint256 fee; // A one-time redeem fee for the token
    }

    /**
     * @notice Struct for tracking the total and claimed debt amounts for a specific BTC token.
     * @param totalDebts The total debt amount for a specific BTC token.
     * @param totalCleared The total cleared debt amount for a specific BTC token.
     */
    struct TokenDebtInfo {
        uint256 totalDebts;
        uint256 totalCleared;
    }

    /**
     * @notice Mapping of user addresses to their delayed redeem information.
     * Internal, with an external getter function named `userRedeems`.
     */
    mapping(address => UserDelayedRedeems) internal _userRedeems;

    /**
     * @notice Mapping of token addresses to debt information for each btc token.
     */
    mapping(address => TokenDebtInfo) public tokenDebts;

    /**
     * @notice Mapping to store the whitelist status of accounts.
     * Only addresses in the whitelist can redeem using uniBTC.
     */
    mapping(address => bool) private whitelist;

    /**
     * @notice Mapping to store the status of specific BTC tokens.
     * Only tokens in the BTC list (wrapped or native BTC) can be redeemed using uniBTC.
     */
    mapping(address => bool) private btclist;

    /**
     * @notice Flag to enable or disable the whitelist feature.
     * If enabled, only whitelisted addresses can redeem using uniBTC.
     */
    bool public whitelistEnabled;

    /**
     * @notice The maximum quota for tokens per redemption.
     */
    mapping(address => uint256) public maxQuotas;

    /**
     * @notice Redeem quota base for different BTC tokens over a defined historical timestamp duration.
     */
    mapping(address => uint256) public quotaBases;

    /**
     * @notice The redeem amount per second for each specific BTC token.
     */
    mapping(address => uint256) public quotaRates;

    /**
     * @notice Records the last rebase timestamp for each specific BTC token.
     */
    mapping(address => uint256) public lastRebaseTimestamps;

    /**
     * @notice Defines the native BTC token.
     */
    address public constant NATIVE_BTC =
        address(0xbeDFFfFfFFfFfFfFFfFfFFFFfFFfFFffffFFFFFF);

    /**
     * @notice Used for converting certain wrapped BTC tokens to 18 decimals.
     */
    uint256 public constant EXCHANGE_RATE_BASE = 1e10;

    /**
     * @notice Principal redemption period.
     */
    uint256 public redeemPrincipalDelay;

    /**
     * @notice Mapping to store the blacklist status of accounts.
     * Only accounts not in the blacklist can redeem using uniBTC.
     */
    mapping(address => bool) private blacklist;

    /**
     * @notice Mapping to store the status of paused tokens.
     * Only tokens not in the `pausedTokens` can be used for redemption or specific BTC token claims.
     */
    mapping(address => bool) private pausedTokens;

    /**
     * @notice Tracks the user redeem fee rate for the contract.
     */
    uint256 public redeemFeeRate;

    /**
     * @notice Tracks the redeem fee for the contract.
     */
    uint256 public managementFee;

    /// update 2025-7-2, add green channel feature
    /**
     * @notice Mapping to store the fast lane status of accounts.
     * If enabled, users can redeem with uniBTC using retain amount.
     */
    mapping(address => bool) public fastLanes;

    /**
     * @notice The maximum amount of tokens that can be redeemed in the fast lane.
     * This is used to limit the amount of tokens that can be redeemed in a single transaction.
     */
    mapping(address => uint256) public retainAmounts;

    /**
     * @notice Tracks the user cancel fee rate for the contract.
     */
    uint256 public cancelFeeRate;

    /**
     * @notice The management fee for the contract.
     * This is used to cover the costs of managing the contract.
     */
    mapping(address => mapping(uint256 => uint256)) public redeemFees;

    /**
     * @notice If users are allowed to redeem native BTC, native BTCs will be transferred here first and then be claimed by users.
     */
    receive() external payable {}

    /**
     * ======================================================================================
     *
     * CONSTRUCTOR
     *
     * ======================================================================================
     */

    /**
     * @dev Disables the ability to call any additional initializer functions.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * ======================================================================================
     *
     * MODIFIERS
     *
     * ======================================================================================
     */

    /**
     * @dev Modifier to ensure the caller is whitelisted.
     */
    modifier onlyWhitelisted() {
        require(!whitelistEnabled || whitelist[msg.sender], "USR009");
        _;
    }

    /**
     * @dev Modifier to ensure the caller is not blacklisted.
     */
    modifier onlyNotBlacklisted() {
        require(!blacklist[msg.sender], "USR009");
        _;
    }

    /**
     * ======================================================================================
     *
     * ADMIN
     *
     * ======================================================================================
     */

    /**
     * @notice Initializes the contract with admin and token settings.
     * @param _defaultAdmin The default admin address (RBAC).
     * @param _uniBTC The address of the ERC20 uniBTC token.
     * @param _vault The address of the Bedrock Vault contract.
     * @param _redeemDelay The delay time before claiming a delayed redeem.
     * @param _whitelistEnabled Enables or disables the whitelist feature.
     */
    function initialize(
        address _defaultAdmin,
        address _uniBTC,
        address _vault,
        uint256 _redeemDelay,
        bool _whitelistEnabled
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        require(_defaultAdmin != address(0x0), "SYS001");
        require(_uniBTC != address(0x0), "SYS001");
        require(_vault != address(0x0), "SYS001");

        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(PAUSER_ROLE, _defaultAdmin);

        uniBTC = _uniBTC;
        vault = _vault;
        _setWhitelistEnabled(_whitelistEnabled);
        _setRedeemPrincipalDelay(MAX_REDEEM_DELAY);
        _setRedeemDelay(_redeemDelay);
        _setRedeemFeeRate(DEFAULT_REDEEM_FEE_RATE);
    }

    /**
     * @dev Pauses the contract.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses the contract.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Sets a new delay redeem delay.
     * @param _newDelay New delay time, after which users can claim the delayed redeem.
     */
    function setRedeemDelay(
        uint256 _newDelay
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRedeemDelay(_newDelay);
    }

    /**
     * @dev Adds tokens to the BTC list for redeeming with uniBTC.
     * @param _tokens List of wrapped or native BTC tokens to be added.
     */
    function addToBtclist(
        address[] calldata _tokens
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            btclist[_tokens[i]] = true;
        }
        emit BtclistAdded(_tokens);
    }

    /**
     * @dev Removes tokens from the BTC list for redeeming with uniBTC.
     * @param _tokens List of wrapped or native BTC tokens to be removed.
     */
    function removeFromBtclist(
        address[] calldata _tokens
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            btclist[_tokens[i]] = false;
        }
        emit BtclistRemoved(_tokens);
    }

    /**
     * @dev Enables or disables the whitelist feature.
     * @param _enabled True if only whitelisted accounts can redeem with uniBTC.
     */
    function setWhitelistEnabled(
        bool _enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setWhitelistEnabled(_enabled);
    }

    /**
     * @dev Adds accounts to the whitelist, allowing them to redeem with uniBTC.
     * @param _accounts List of accounts to be added to the whitelist.
     */
    function addToWhitelist(
        address[] calldata _accounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _accounts.length; i++) {
            whitelist[_accounts[i]] = true;
        }
        emit WhitelistAdded(_accounts);
    }

    /**
     * @dev Removes accounts from the whitelist, restricting their redemption access.
     * @param _accounts List of accounts to be removed from the whitelist.
     */
    function removeFromWhitelist(
        address[] calldata _accounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _accounts.length; i++) {
            whitelist[_accounts[i]] = false;
        }
        emit WhitelistRemoved(_accounts);
    }

    /**
     * @dev Adds accounts to the blacklist, preventing them from claiming delayed redeems.
     * @param _accounts List of accounts to be blacklisted.
     */
    function addToBlacklist(
        address[] calldata _accounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _accounts.length; i++) {
            blacklist[_accounts[i]] = true;
        }
        emit BlacklistAdded(_accounts);
    }

    /**
     * @dev Removes accounts from the blacklist, allowing them to claim delayed redeems.
     * @param _accounts List of accounts to be removed from the blacklist.
     */
    function removeFromBlacklist(
        address[] calldata _accounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _accounts.length; i++) {
            blacklist[_accounts[i]] = false;
        }
        emit BlacklistRemoved(_accounts);
    }

    /**
     * @dev Adds tokens to the paused token list, blocking them from being redeemed or claimed.
     * @param _tokens List of tokens to be paused.
     */
    function pauseTokens(
        address[] calldata _tokens
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            pausedTokens[_tokens[i]] = true;
        }
        emit TokensPaused(_tokens);
    }

    /**
     * @dev Removes tokens from the paused token list, allowing them to be redeemed or claimed.
     * @param _tokens List of tokens to be resumed.
     */
    function unpauseTokens(
        address[] calldata _tokens
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            pausedTokens[_tokens[i]] = false;
        }
        emit TokensUnpaused(_tokens);
    }

    /**
     * @dev Sets the maximum quota for each redeemable token type.
     * @param _tokens List of token addresses.
     * @param _quotas List of maximum quota for each token.
     */
    function setMaxQuotaForTokens(
        address[] calldata _tokens,
        uint256[] calldata _quotas
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tokens.length == _quotas.length, "SYS006");
        for (uint256 i = 0; i < _tokens.length; i++) {
            require(_quotas[i] < MAX_DAILY_REDEEM_CAP, "USR013");
            emit MaxQuotaSet(_tokens[i], maxQuotas[_tokens[i]], _quotas[i]);
            maxQuotas[_tokens[i]] = _quotas[i];
        }
    }

    /**
     * @dev Withdraws the redeem management fee.
     * @param _amount Amount to withdraw.
     * @param _recipient Recipient address for the fee withdrawal.
     */
    function withdrawManagementFee(
        uint256 _amount,
        address _recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_recipient != address(0x0), "SYS001");
        require(_amount <= managementFee, "USR003");
        managementFee -= _amount;
        IERC20(uniBTC).safeTransfer(_recipient, _amount);
        emit ManagementFeeWithdrawn(_recipient, _amount);
    }

    /**
     * @dev Sets the redeem amount per second for each specific BTC token.
     * @param _tokens List of BTC tokens.
     * @param _quotas Number of tokens per second.
     */
    function setQuotaRates(
        address[] calldata _tokens,
        uint256[] calldata _quotas
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tokens.length == _quotas.length, "SYS006");
        uint256 maxQuotaPerSecond = MAX_DAILY_REDEEM_CAP / SECONDS_IN_A_DAY;
        for (uint256 i = 0; i < _tokens.length; i++) {
            require(_quotas[i] <= maxQuotaPerSecond, "USR013");

            // For this instance, the old quota per second must be applied to rebase the quota
            // and update the timestamp.
            _rebase(_tokens[i]);
            emit RateSet(_tokens[i], quotaRates[_tokens[i]], _quotas[i]);
            quotaRates[_tokens[i]] = _quotas[i];
        }
    }

    /**
     * @dev Sets a new delay for principal redemption.
     * @param _newDelay New delay time after which users can claim the principal.
     */
    function setRedeemPrincipalDelay(
        uint256 _newDelay
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRedeemPrincipalDelay(_newDelay);
    }

    /**
     * @dev Sets the redeem management rate for the contract.
     * @param _newFeeRate The new value for the redeem management rate,
     * which is used to calculate the redemption management fee.
     */
    function setRedeemFeeRate(
        uint256 _newFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRedeemFeeRate(_newFeeRate);
    }

    /**
     * @dev Sets the retain amount for fast lane redemption.
     * @param _tokens List of BTC tokens.
     * @param _balances List of retain amounts for each token.
     */
    function setRetainAmounts(
        address[] calldata _tokens,
        uint256[] calldata _balances
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tokens.length == _balances.length, "SYS006");
        for (uint256 i = 0; i < _tokens.length; i++) {
            retainAmounts[_tokens[i]] = _balances[i];
        }
        emit RetainAmountsSet(_tokens,_balances);
    }

    /**
     * @dev Sets the fast lane status for multiple accounts.
     * @param _accounts List of accounts to set fast lane status.
     * @param _fastLaneStatus Corresponding fast lane status for each account.
     */
    function setFastLane(
        address[] calldata _accounts,
        bool[] calldata _fastLaneStatus
    ) external onlyRole(OPERATOR_ROLE) {
        require(_accounts.length == _fastLaneStatus.length, "SYS006");
        for (uint256 i = 0; i < _accounts.length; i++) {
            fastLanes[_accounts[i]] = _fastLaneStatus[i];
        }
        emit FastLaneSet(_accounts, _fastLaneStatus);
    }

    /**
     * @dev Sets the cancel fee rate for the contract.
     * @param _newFeeRate The new value for the cancel fee rate,
     * which is used to calculate the cancellation fee.
     */
    function setCancelFeeRate(
        uint256 _newFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newFeeRate <= REDEEM_FEE_RATE_RANGE, "USR011");
        emit CancelFeeRateSet(cancelFeeRate, _newFeeRate);
        cancelFeeRate = _newFeeRate;
    }

    /**
     * ======================================================================================
     *
     * EXTERNAL FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @notice Creates a delayed redemption request for the `amount` to `msg.sender`.
     * @dev Checks if the provided amount meets the redemption requirements for the user.
     * @param token The specific BTC token address.
     * @param amount The amount of BTC tokens to be redeemed with a delay.
     */
    function createDelayedRedeem(
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyWhitelisted {
        //================================================================================================
        // 1. Validate the legality of the token and amount, then update the redemption baseline by
        //    adjusting the base quota and timestamp.
        //================================================================================================
        require(btclist[token] && !pausedTokens[token], "SYS003");
        uint256 quota = _getQuota(token);
        require(quota >= amount + tokenDebts[token].totalDebts, "USR010");

        // This time, the quota and timestamp need to be rebased.
        _rebase(token);

        //================================================================================================
        // 2. Create a delayed redemption request for the user.
        //================================================================================================
        if (amount != 0) {
            // Lock the unibtc tokens within the contract.
            IERC20(uniBTC).safeTransferFrom(msg.sender, address(this), amount);

            // The user is required to pay the redemption fee.
            uint224 userRedeemAmount = uint224(
                (amount * (REDEEM_FEE_RATE_RANGE - redeemFeeRate)) /
                    REDEEM_FEE_RATE_RANGE
            );
            uint256 userRedeemFee = amount - userRedeemAmount;

            DelayedRedeem memory delayedRedeem = DelayedRedeem({
                amount: userRedeemAmount,
                createdAt: uint32(block.timestamp),
                token: token
            });
            _userRedeems[msg.sender].delayedRedeems.push(delayedRedeem);

            tokenDebts[token].totalDebts += userRedeemAmount;
            redeemFees[msg.sender][_userRedeems[msg.sender].delayedRedeems.length - 1] = userRedeemFee;

            emit DelayedRedeemCreated(
                msg.sender,
                token,
                userRedeemAmount,
                _userRedeems[msg.sender].delayedRedeems.length - 1,
                userRedeemFee
            );
        }
    }

    /**
     * @notice Claims delayed redemptions that have passed the `redeemDelay` period for `msg.sender`.
     * @dev The caller controls when funds are released to `msg.sender` once the redemption is claimable.
     * @param maxNumberOfDelayedRedeemsToClaim Limits the maximum number of delayed redemptions to claim in a loop.
     */
    function claimDelayedRedeems(
        uint256 maxNumberOfDelayedRedeemsToClaim
    ) external nonReentrant whenNotPaused onlyNotBlacklisted {
        _claimDelayedRedeems(msg.sender, maxNumberOfDelayedRedeemsToClaim);
    }

    /**
     * @notice Claims all delayed redemptions that have passed the `redeemDelay` period for `msg.sender`.
     */
    function claimDelayedRedeems()
        external
        nonReentrant
        whenNotPaused
        onlyNotBlacklisted
    {
        _claimDelayedRedeems(msg.sender, type(uint256).max);
    }

    /**
     * @notice Claims delayed redemption principals that have passed the `redeemPrincipalDelay` period.
     * @dev The caller controls when funds are released once the principal becomes claimable.
     * @param maxNumberOfDelayedRedeemsToClaim Limits the maximum number of delayed redemption principals to claim in a loop.
     */
    function claimPrincipals(
        uint256 maxNumberOfDelayedRedeemsToClaim
    ) external nonReentrant whenNotPaused onlyNotBlacklisted {
        _claimPrincipals(msg.sender, maxNumberOfDelayedRedeemsToClaim);
    }

    /**
     * @notice Claims all delayed redemption principals that have passed the `redeemPrincipalDelay` period.
     */
    function claimPrincipals()
        external
        nonReentrant
        whenNotPaused
        onlyNotBlacklisted
    {
        _claimPrincipals(msg.sender, type(uint256).max);
    }

    /**
     * @notice Getter function for retrieving the delayed redemption records of a user.
     * @param user The account that created the delayed redemption.
     * @return The UserDelayedRedeems struct for the specified user.
     */
    function userRedeems(
        address user
    ) external view returns (UserDelayedRedeems memory) {
        return _userRedeems[user];
    }

    /**
     * @notice Getter function for retrieving a specific delayed redemption at the `index` position from the user's array.
     * @param user The account that created the delayed redemption.
     * @param index The index of the delayed redemption in the user's array.
     * @return The DelayedRedeem struct at the specified `index` position.
     */
    function userDelayedRedeemByIndex(
        address user,
        uint256 index
    ) external view returns (DelayedRedeem memory) {
        return _userRedeems[user].delayedRedeems[index];
    }

    /**
     * @notice Getter function for retrieving the length of the user's delayed redemption array.
     * @param user The account that created the delayed redemption.
     * @return The length of the user's delayed redemption array.
     */
    function userRedeemsLength(address user) external view returns (uint256) {
        return _userRedeems[user].delayedRedeems.length;
    }

    /**
     * @notice Checks if a delayed redemption at the specified `index` in the user's array is currently claimable.
     * @param user The account that created the delayed redemption.
     * @param index The index of the delayed redemption in the user's array.
     * @return True if the delayed redemption at the specified `index` is currently claimable, false otherwise.
     */
    function canClaimDelayedRedeem(
        address user,
        uint256 index
    ) external view returns (bool) {
        return ((index >= _userRedeems[user].delayedRedeemsCompleted) &&
            (block.timestamp >=
                _userRedeems[user].delayedRedeems[index].createdAt +
                    redeemDelay));
    }

    /**
     * @notice Checks if the principal of a delayed redemption at the specified `index` in the user's array is claimable.
     * @param user The account that created the delayed redemption.
     * @param index The index of the delayed redemption in the user's array.
     * @return True if the principal of the delayed redemption at the specified `index` is claimable, false otherwise.
     */
    function canClaimDelayedRedeemPrincipal(
        address user,
        uint256 index
    ) external view returns (bool) {
        return ((index >= _userRedeems[user].delayedRedeemsCompleted) &&
            (block.timestamp >=
                _userRedeems[user].delayedRedeems[index].createdAt +
                    redeemPrincipalDelay));
    }

    /**
     * @notice Getter function to retrieve all unclaimed delayed redemptions for a user.
     * @param user The account that created the delayed redemption.
     * @return An array of DelayedRedeem structs for all unclaimed delayed redemptions of the user.
     */
    function getUserDelayedRedeems(
        address user
    ) external view returns (DelayedRedeem[] memory) {
        uint256 delayedRedeemsCompleted = _userRedeems[user]
            .delayedRedeemsCompleted;
        uint256 totalDelayedRedeems = _userRedeems[user].delayedRedeems.length;
        uint256 userDelayedRedeemsLength = totalDelayedRedeems -
            delayedRedeemsCompleted;
        DelayedRedeem[] memory userDelayedRedeems = new DelayedRedeem[](
            userDelayedRedeemsLength
        );
        for (uint256 i = 0; i < userDelayedRedeemsLength; i++) {
            userDelayedRedeems[i] = _userRedeems[user].delayedRedeems[
                delayedRedeemsCompleted + i
            ];
        }
        return userDelayedRedeems;
    }

    /**
     * @notice Getter function to retrieve all currently claimable delayed redemptions for a user.
     * @param user The account that created the delayed redemption.
     * @return An array of DelayedRedeem structs for all claimable delayed redemptions of the user.
     */
    function getClaimableUserDelayedRedeems(
        address user
    ) external view returns (DelayedRedeem[] memory) {
        uint256 delayedRedeemsCompleted = _userRedeems[user]
            .delayedRedeemsCompleted;
        uint256 totalDelayedRedeems = _userRedeems[user].delayedRedeems.length;
        uint256 userDelayedRedeemsLength = totalDelayedRedeems -
            delayedRedeemsCompleted;

        uint256 firstNonClaimableRedeemIndex = userDelayedRedeemsLength;

        //------------------------------------------------------------------------------------------
        // 1. Find the first delayed redemption that cannot be claimed.
        //------------------------------------------------------------------------------------------
        for (uint256 i = 0; i < userDelayedRedeemsLength; i++) {
            DelayedRedeem memory delayedRedeem = _userRedeems[user]
                .delayedRedeems[delayedRedeemsCompleted + i];

            // Check if the delayed redemption can be claimed, and break the loop as soon as a delayed
            // redemption is found that cannot be claimed.
            if (block.timestamp < delayedRedeem.createdAt + redeemDelay) {
                firstNonClaimableRedeemIndex = i;
                break;
            }
        }

        //------------------------------------------------------------------------------------------
        // 2. Create an array containing all claimable delayed redemptions for the user.
        //    This array will only include redemptions where the required delay has passed,
        //    making them claimable.
        //------------------------------------------------------------------------------------------
        uint256 numberOfClaimableRedeems = firstNonClaimableRedeemIndex;
        DelayedRedeem[] memory claimableDelayedRedeems = new DelayedRedeem[](
            numberOfClaimableRedeems
        );

        if (numberOfClaimableRedeems != 0) {
            for (uint256 i = 0; i < numberOfClaimableRedeems; i++) {
                claimableDelayedRedeems[i] = _userRedeems[user].delayedRedeems[
                    delayedRedeemsCompleted + i
                ];
            }
        }
        return claimableDelayedRedeems;
    }

    /**
     * @notice Retrieves the current redemption cap for a specific BTC token.
     * @param token The BTC token address for which to get the current redemption cap.
     * @return The current redemption cap for the specified token.
     */
    function getCurrentCap(address token) external view returns (uint256) {
        if (btclist[token]) {
            return (_getQuota(token) - tokenDebts[token].totalDebts);
        }
        return (0);
    }

    /**
     * @dev Checks if an account is in the whitelist.
     * @param account The address of the account to check.
     * @return True if the account is in the whitelist, false otherwise.
     */
    function isWhitelisted(address account) external view returns (bool) {
        return whitelist[account];
    }

    /**
     * @dev Checks if a specific BTC token is in the BTC list.
     * @param token The BTC token address to check.
     * @return True if the token is in the BTC list, false otherwise.
     */
    function isBtclisted(address token) external view returns (bool) {
        return btclist[token];
    }

    /**
     * @dev Checks if an account is in the blacklist.
     * @param account The address of the account to check.
     * @return True if the account is in the blacklist, false otherwise.
     */
    function isBlacklisted(address account) external view returns (bool) {
        return blacklist[account];
    }

    /**
     * @dev Checks if a specific BTC token is paused.
     * @param token The BTC token address to check.
     * @return True if the token is paused, false otherwise.
     */
    function isPausedToken(address token) external view returns (bool) {
        return pausedTokens[token];
    }

    /**
     * @notice Retrieves the user's delayed redeems that are ready to be claimed.
     * @param recipient The address of the user whose delayed redeems are being queried.
     * @param maxNumberOfDelayedRedeemsToClaim The maximum number of delayed redeems to claim in a single call.
     * @return An array of DebtTokenAmount structs representing the user's delayed redeems.
     */
    function getUserRedeem(
        address recipient,
        uint256 maxNumberOfDelayedRedeemsToClaim
    ) external view returns (DebtTokenAmount[] memory) {
        uint256 delayedRedeemsCompletedBefore = _userRedeems[recipient]
            .delayedRedeemsCompleted;
        DebtTokenAmount[] memory debtAmounts;
        uint256 numToClaim = 0;

        //================================================================================================
        // 1. Get the length of debt that need to be repaid and the amount of each type of debt.
        //================================================================================================
        (numToClaim, debtAmounts) = _getDebtTokenAmount(
            recipient,
            delayedRedeemsCompletedBefore,
            redeemDelay,
            maxNumberOfDelayedRedeemsToClaim
        );

        return debtAmounts;
    }

    /**
     * @notice Retrieves the user's delayed redeems that are ready to be claimed for principal.
     * @param recipient The address of the user whose delayed redeems are being queried.
     * @param maxNumberOfDelayedRedeemsToClaim The maximum number of delayed redeems to claim in a single call.
     * @return An array of DebtTokenAmount structs representing the user's delayed redeems for principal.
     */
    function getUserPrincipal(
        address recipient,
        uint256 maxNumberOfDelayedRedeemsToClaim
    ) external view returns (DebtTokenAmount[] memory) {
        uint256 delayedRedeemsCompletedBefore = _userRedeems[recipient]
            .delayedRedeemsCompleted;
        DebtTokenAmount[] memory debtAmounts;
        uint256 numToClaim = 0;

        //================================================================================================
        // 1. Get the length of debt that need to be repaid and the amount of each type of debt.
        //================================================================================================
        (numToClaim, debtAmounts) = _getDebtTokenAmount(
            recipient,
            delayedRedeemsCompletedBefore,
            redeemPrincipalDelay,
            maxNumberOfDelayedRedeemsToClaim
        );

        return debtAmounts;
    }

    /**
     * ======================================================================================
     *
     * INTERNAL FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @notice Internal function to update `redeemDelay`. Includes a sanity check and emits an event.
     * @param newDelay The new delayed time for the redemption delay.
     */
    function _setRedeemDelay(uint256 newDelay) internal {
        require(newDelay <= MAX_REDEEM_DELAY, "USR012");
        emit RedeemDelaySet(redeemDelay, newDelay);
        redeemDelay = newDelay;
    }

    /**
     * @notice Internal function to update `redeemPrincipalDelay`. Includes a sanity check and emits an event.
     * @param newDelay The new delayed time for the redemption principal delay.
     */
    function _setRedeemPrincipalDelay(uint256 newDelay) internal {
        require(newDelay <= MAX_REDEEM_DELAY, "USR012");
        emit RedeemPrincipalDelaySet(redeemPrincipalDelay, newDelay);
        redeemPrincipalDelay = newDelay;
    }

    /**
     * @notice Internal function to update `whitelistEnabled`.
     * @param enabled The new boolean value for whitelist status.
     */
    function _setWhitelistEnabled(bool enabled) internal {
        emit WhitelistEnabledSet(enabled);
        whitelistEnabled = enabled;
    }

    /**
     * @notice Internal function to update `redeemFeeRate`.
     * @param newFeeRate The new management rate for redemption.
     */
    function _setRedeemFeeRate(uint256 newFeeRate) internal {
        require(newFeeRate <= REDEEM_FEE_RATE_RANGE, "USR011");
        emit RedeemFeeRateSet(redeemFeeRate, newFeeRate);
        redeemFeeRate = newFeeRate;
    }

    /**
     * @notice Internal function used by both overloaded `claimDelayedRedeems` functions.
     * @param recipient The account to receive the claimed delayed redeems.
     * @param maxNumberOfDelayedRedeemsToClaim The maximum number of delayed redeems to claim in a single call.
     */
    function _claimDelayedRedeems(
        address recipient,
        uint256 maxNumberOfDelayedRedeemsToClaim
    ) internal {
        uint256 delayedRedeemsCompletedBefore = _userRedeems[recipient]
            .delayedRedeemsCompleted;
        uint256 numToClaim = 0;
        DebtTokenAmount[] memory debtAmounts;

        //================================================================================================
        // 1. Get the length of debt that need to be repaid and the amount of each type of debt.
        //================================================================================================
        (numToClaim, debtAmounts) = _getDebtTokenAmount(
            recipient,
            delayedRedeemsCompletedBefore,
            redeemDelay,
            maxNumberOfDelayedRedeemsToClaim
        );

        //================================================================================================
        // 2. Debt exists and can be repaid through the redemption of various BTC tokens.
        //================================================================================================
        if (numToClaim > 0) {
            // Mark the ith delayed redemptions as claimed.
            _userRedeems[recipient].delayedRedeemsCompleted =
                delayedRedeemsCompletedBefore +
                numToClaim;

            // Transfer the delayed redemptions to the recipient.
            uint256 burnAmount = 0;
            uint256 totalFee = 0;
            bytes memory data;
            for (uint256 i = 0; i < debtAmounts.length; i++) {
                address token = debtAmounts[i].token;
                require(!pausedTokens[token], "SYS003");
                uint256 uniBTCAmount = debtAmounts[i].amount;
                uint256 tokenFee = debtAmounts[i].fee;
                // The user is required to pay the redemption fee.
                managementFee += tokenFee;
                totalFee += tokenFee;
                uint256 amountToSend = _amounts(token, uniBTCAmount);
                tokenDebts[token].totalCleared += uniBTCAmount;
                burnAmount += uniBTCAmount;
                if (token == NATIVE_BTC) {
                    // Check vault balance and fast lane logic
                    uint256 vaultBalance = address(vault).balance;
                    _useFastLane(recipient, token, vaultBalance, amountToSend);
                    // Transfer the native token to the recipient.
                    IVault(vault).execute(address(this), "", amountToSend);
                    (bool success, ) = payable(recipient).call{
                        value: amountToSend
                    }("");
                    if (success == false) {
                        revert("USR010");
                    }
                } else {
                    // Check vault balance and fast lane logic
                    uint256 vaultBalance = IERC20(token).balanceOf(vault);
                    _useFastLane(recipient, token, vaultBalance, amountToSend);
                    data = abi.encodeWithSelector(
                        IERC20.transfer.selector,
                        recipient,
                        amountToSend
                    );

                    // Transfer the specified ERC-20 token to the recipient’s address.
                    IVault(vault).execute(token, data, 0);
                }
                emit DelayedRedeemsClaimed(recipient, token, amountToSend);
            }

            // Burn the amount of unBTC corresponding to the claimed redemption.
            IERC20(uniBTC).safeApprove(vault, 0);
            IERC20(uniBTC).safeApprove(vault, burnAmount);

            data = abi.encodeWithSelector(
                IMintableContract.burnFrom.selector,
                address(this),
                burnAmount
            );
            IVault(vault).execute(uniBTC, data, 0);

            emit DelayedRedeemsCompleted(
                recipient,
                burnAmount,
                delayedRedeemsCompletedBefore + numToClaim,
                totalFee
            );
        }
    }

    /**
     * @notice Internal function used by both overloaded `claimPrincipals` functions.
     * @param recipient The account to receive the claimed principals.
     * @param maxNumberOfDelayedRedeemsToClaim The maximum number of delayed redeems to claim in a single call.
     */
    function _claimPrincipals(
        address recipient,
        uint256 maxNumberOfDelayedRedeemsToClaim
    ) internal {
        uint256 delayedRedeemsCompletedBefore = _userRedeems[recipient]
            .delayedRedeemsCompleted;
        uint256 numToClaim = 0;
        DebtTokenAmount[] memory debtAmounts;

        //================================================================================================
        // 1. Get the length of debt that need to be repaid and the amount of each type of debt.
        //================================================================================================
        (numToClaim, debtAmounts) = _getDebtTokenAmount(
            recipient,
            delayedRedeemsCompletedBefore,
            redeemPrincipalDelay,
            maxNumberOfDelayedRedeemsToClaim
        );

        //================================================================================================
        // 2. Debt is present and can be repaid through principal redemption.
        //================================================================================================
        if (numToClaim > 0) {
            // Mark the ith delayed redeem as successfully claimed.
            _userRedeems[recipient].delayedRedeemsCompleted =
                delayedRedeemsCompletedBefore +
                numToClaim;

            uint256 amountToSend = 0;
            uint256 totalPrincipal = 0;
            for (uint256 i = 0; i < debtAmounts.length; i++) {
                address token = debtAmounts[i].token;
                uint256 uniBTCAmount = debtAmounts[i].amount;
                uint256 tokenFee = debtAmounts[i].fee;
                tokenDebts[token].totalCleared += uniBTCAmount;
                uint256 principalAmount = uniBTCAmount + tokenFee;
                totalPrincipal += principalAmount;
                emit DelayedRedeemsPrincipalClaimed(
                    recipient,
                    token,
                    uniBTCAmount,
                    principalAmount
                );
            }
            // The user is required to pay the cancel fee.
            amountToSend = (totalPrincipal * (REDEEM_FEE_RATE_RANGE - cancelFeeRate)) / REDEEM_FEE_RATE_RANGE;
            uint256 userCancelFee = totalPrincipal - amountToSend;
            //the cancel fee is added to the management fee
            managementFee += userCancelFee;

            IERC20(uniBTC).safeTransfer(recipient, amountToSend);
            emit DelayedRedeemsPrincipalCompleted(
                recipient,
                amountToSend,
                delayedRedeemsCompletedBefore + numToClaim,
                userCancelFee
            );
        }
    }

    /**
     * @notice Internal function to reset the base quota and timestamp for a specific BTC token.
     * @param token The BTC token address for which to rebase.
     */
    function _rebase(address token) internal {
        uint256 quota = _getQuota(token);
        quotaBases[token] = quota;
        lastRebaseTimestamps[token] = block.timestamp;
    }

    /**
     * @dev Calculates the valid amount of wrapped or native BTC for a specified token.
     * @param token The specific BTC token.
     * @param amount The redemption amount in uniBTC.
     * @return The valid delayed redemption amount in BTC.
     */
    function _amounts(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        if (token == NATIVE_BTC) {
            return (amount * EXCHANGE_RATE_BASE);
        }
        uint8 decs = ERC20(token).decimals();
        if (decs == 8) return (amount);
        if (decs == 18) {
            return (amount * EXCHANGE_RATE_BASE);
        }
        return (0);
    }

    /**
     * @dev Retrieves the cumulative redemption quota for a specific BTC token.
     * @param token The specific BTC token.
     */
    function _getQuota(address token) internal view returns (uint256) {
        uint256 quota = quotaBases[token] +
            (block.timestamp - lastRebaseTimestamps[token]) *
            quotaRates[token];
        uint256 maxFreeQuota = tokenDebts[token].totalDebts + maxQuotas[token];
        if (quota <= maxFreeQuota) {
            return (quota);
        }
        return (maxFreeQuota);
    }

    /**
     * @dev Retrieves the list of claimable debts from _userRedeems based on the delay timestamp.
     * @param recipient The account that created the delayed redemption.
     * @param delayedRedeemsCompletedBefore The number of delayed redemptions that have already been completed.
     * @param delayTimestamp The delay time for claiming a delayed redemption.
     * @param maxNumberOfDelayedRedeemsToClaim The maximum number of delayed redemptions to loop through for claiming.
     * @return The number of delayed redemptions that can be claimed, and an array of DebtTokenAmount records that include the debt token and the associated amount.
     */
    function _getDebtTokenAmount(
        address recipient,
        uint256 delayedRedeemsCompletedBefore,
        uint256 delayTimestamp,
        uint256 maxNumberOfDelayedRedeemsToClaim
    ) internal view returns (uint256, DebtTokenAmount[] memory) {
        uint256 redeemsLength = _userRedeems[recipient].delayedRedeems.length;
        uint256 numToClaim = 0;

        //================================================================================================
        // 1. Check how many debts can be redeemed.
        //================================================================================================
        while (
            numToClaim < maxNumberOfDelayedRedeemsToClaim &&
            (delayedRedeemsCompletedBefore + numToClaim) < redeemsLength
        ) {
            // Copy the delayedRedeem from storage to memory.
            DelayedRedeem memory delayedRedeem = _userRedeems[recipient]
                .delayedRedeems[delayedRedeemsCompletedBefore + numToClaim];

            // Check if each delayedRedeem is claimable, and exit the loop immediately
            // once a non-claimable delayedRedeem is encountered.
            if (block.timestamp < delayedRedeem.createdAt + delayTimestamp) {
                break;
            }

            // Increment i to reflect the processing of the current delayedRedeem being claimed.
            unchecked {
                ++numToClaim;
            }
        }

        //================================================================================================
        // 2. Count the types of debt and the amount of each debt type.
        //================================================================================================
        if (numToClaim > 0) {
            DebtTokenAmount[] memory debtAmounts = new DebtTokenAmount[](
                numToClaim
            );
            uint256 tokenCount = 0;
            for (uint256 i = 0; i < numToClaim; i++) {
                DelayedRedeem memory delayedRedeem = _userRedeems[recipient]
                    .delayedRedeems[delayedRedeemsCompletedBefore + i];
                bool found = false;
                uint256 fee = _getFee(
                    recipient,
                    delayedRedeemsCompletedBefore + i
                );
                for (uint256 j = 0; j < tokenCount; j++) {
                    if (debtAmounts[j].token == delayedRedeem.token) {
                        debtAmounts[j].amount += delayedRedeem.amount;
                        debtAmounts[j].fee += fee;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    debtAmounts[tokenCount] = DebtTokenAmount({
                        token: delayedRedeem.token,
                        amount: delayedRedeem.amount,
                        fee: fee
                    });
                    tokenCount++;
                }
            }

            // The number of unique token types matches the total number of delayed redemption requests.
            if (tokenCount == debtAmounts.length) {
                return (numToClaim, debtAmounts);
            }

            // Some delayed redemption requests involve the same token type.
            DebtTokenAmount[] memory finalAmounts = new DebtTokenAmount[](
                tokenCount
            );
            for (uint256 k = 0; k < tokenCount; k++) {
                finalAmounts[k] = debtAmounts[k];
            }
            return (numToClaim, finalAmounts);
        }

        return (0, new DebtTokenAmount[](0));
    }

    /**
     * @notice Internal function to update the fast lane status for a recipient.
     * @param recipient The address of the recipient.
     * @param token The specific BTC token address.
     * @param vaultBalance The balance of the vault for the specified token.
     * @param amountToSend The amount to be sent to the recipient.
     */
    function _useFastLane(address recipient, address token, uint256 vaultBalance, uint256 amountToSend) internal {
        if (vaultBalance < retainAmounts[token] + amountToSend) {
            require(fastLanes[recipient], "USR015");
            require(vaultBalance >= retainAmounts[token], "USR027");
            require(retainAmounts[token] >= amountToSend, "USR015");
            retainAmounts[token] = retainAmounts[token] - amountToSend;
            fastLanes[recipient] = false;
        }
    }

    /**
     * @notice Internal function to retrieve the fee for a specific recipient and index.
     * @param recipient The address of the recipient.
     * @param index The index of the delayed redeem in the recipient's array.
     * @return The fee amount for the specified recipient and index.
     */
    function _getFee(address recipient, uint256 index) internal view returns (uint256) {
        return redeemFees[recipient][index];
    }

    /**
     * ======================================================================================
     *
     * EVENTS
     *
     * ======================================================================================
     */

    /**
     * @notice Event emitted when a delayedRedeem is created.
     */
    event DelayedRedeemCreated(
        address recipient,
        address token,
        uint256 amount,
        uint256 index,
        uint256 redeemFee
    );

    /**
     * @notice Event emitted when delayedRedeems are claimed.
     */
    event DelayedRedeemsClaimed(
        address recipient,
        address token,
        uint256 claimedAmount
    );

    /**
     * @notice Event emitted when the principal of delayedRedeems is claimed.
     */
    event DelayedRedeemsPrincipalClaimed(
        address recipient,
        address token,
        uint256 debtAmount,
        uint256 principalAmount
    );

    /**
     * @notice Event emitted when delayedRedeems are completed.
     */
    event DelayedRedeemsCompleted(
        address recipient,
        uint256 burnedAmount,
        uint256 delayedRedeemsCompleted,
        uint256 totalFee
    );

    /**
     * @notice Event emitted when the principal of delayedRedeems is completed.
     */
    event DelayedRedeemsPrincipalCompleted(
        address recipient,
        uint256 principalAmount,
        uint256 delayedRedeemsCompleted,
        uint256 totalFee
    );

    /**
     * @notice Event emitted when the `redeemDelay` variable is modified.
     */
    event RedeemDelaySet(uint256 previousDelay, uint256 newDelay);

    /**
     * @notice Event emitted when the `redeemPrincipalDelay` variable is modified.
     */
    event RedeemPrincipalDelaySet(uint256 previousDelay, uint256 newDelay);

    /**
     * @notice Event emitted when tokens are added to the BTC list.
     */
    event BtclistAdded(address[] tokens);

    /**
     * @notice Event emitted when tokens are removed from the BTC list.
     */
    event BtclistRemoved(address[] tokens);

    /**
     * @notice Event emitted when accounts are added to the whitelist.
     */
    event WhitelistAdded(address[] accounts);

    /**
     * @notice Event emitted when accounts are removed from the whitelist.
     */
    event WhitelistRemoved(address[] accounts);

    /**
     * @notice Event emitted when the whitelistEnabled flag is set.
     */
    event WhitelistEnabledSet(bool enabled);

    /**
     * @notice Event emitted when accounts are added to the blacklist.
     */
    event BlacklistAdded(address[] accounts);

    /**
     * @notice Event emitted when accounts are removed from the blacklist.
     */
    event BlacklistRemoved(address[] accounts);

    /**
     * @notice Event emitted when the maximum quota is set.
     */
    event MaxQuotaSet(address token, uint256 previousQuota, uint256 newQuota);

    /**
     * @notice Event emitted when the number of redeemable BTC tokens per second is set.
     */
    event RateSet(address token, uint256 previousQuota, uint256 newQuota);

    /**
     * @notice Event emitted when tokens are added to the paused token list.
     */
    event TokensPaused(address[] tokens);

    /**
     * @notice Event emitted when tokens are removed from the paused token list.
     */
    event TokensUnpaused(address[] tokens);

    /**
     * @notice Event emitted when the redeem fee rate is set.
     */
    event RedeemFeeRateSet(uint256 previousFeeRate, uint256 newFeeRate);

    /**
     * @notice Event emitted when the management fee is withdrawn.
     */
    event ManagementFeeWithdrawn(address recipient, uint256 amount);

    /**
     * @notice Event emitted when the fast lane is set for accounts.
     */
    event FastLaneSet(address[] accounts, bool[] fastLaneStatus);

    /**
     * @notice Event emitted when the retain amounts for fast lane redemption are set.
     */
    event RetainAmountsSet(address[] tokens, uint256[] balances);

    /**
     * @notice Event emitted when the cancel fee rate is set.
     */
    event CancelFeeRateSet(uint256 previousFeeRate, uint256 newFeeRate);
}
