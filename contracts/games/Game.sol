// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {IBank} from "../bank/IBank.sol";
import {IReferral} from "../bank/IReferral.sol";

// import "hardhat/console.sol";

interface IVRFCoordinatorV2 is VRFCoordinatorV2Interface {
    function getFeeConfig()
        external
        view
        returns (
            uint32,
            uint32,
            uint32,
            uint32,
            uint32,
            uint24,
            uint24,
            uint24,
            uint24
        );
}

/// @title Game base contract
/// @author Romuald Hog
/// @notice This should be parent contract of each games.
/// It defines all the games common functions and state variables.
/// @dev All rates are in basis point. Chainlink VRF v2 is used.
abstract contract Game is
    Ownable,
    Pausable,
    Multicall,
    VRFConsumerBaseV2,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /// @notice Bet information struct.
    /// @param resolved Whether the bet has been resolved.
    /// @param user Address of the gamer.
    /// @param token Address of the token.
    /// @param id Bet ID generated by Chainlink VRF.
    /// @param amount The bet amount.
    /// @param blockNumber Block number of the bet used to refund in case Chainlink's callback fail.
    /// @param payout The payout amount.
    /// @param vrfCost The Chainlink VRF cost paid by player.
    struct Bet {
        bool resolved;
        address payable user;
        address token;
        uint256 id;
        uint256 amount;
        uint256 blockNumber;
        uint256 payout;
        uint256 vrfCost;
    }

    /// @notice Chainlink VRF configuration struct.
    /// @param subId Default subscription ID.
    /// @param callbackGasLimit How much gas you would like in your callback to do work with the random words provided.
    /// @param requestConfirmations How many confirmations the Chainlink node should wait before responding.
    /// @param keyHash Hash of the public key used to verify the VRF proof.
    struct ChainlinkConfig {
        uint64 subId;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        bytes32 keyHash;
    }

    /// @notice Chainlink VRF configuration state.
    ChainlinkConfig public chainlinkConfig;

    /// @notice Reference to the VRFCoordinatorV2 deployed contract.
    IVRFCoordinatorV2 public chainlinkCoordinator;

    /// @notice How many random words is needed to resolve a game's bet.
    uint16 private immutable _numRandomWords;

    /// @notice Chainlink price feed.
    AggregatorV3Interface public immutable LINK_ETH_feed;

    /// @notice Maps bets IDs to Bet information.
    mapping(uint256 => Bet) public bets;

    /// @notice Maps users addresses to bets IDs
    mapping(address => uint256[]) internal _userBets;

    /// @notice Token struct.
    /// @param houseEdge House edge rate.
    /// @param VRFSubId Chainlink's VRF subscription ID.
    /// @param partner Address of the partner to manage the token.
    /// @param minBetAmount Minimum bet amount.
    /// @param VRFFees Chainlink's VRF collected fees amount.
    struct Token {
        uint16 houseEdge;
        uint64 VRFSubId;
        address partner;
        uint256 minBetAmount;
        uint256 VRFFees;
    }
    /// @notice Maps tokens addresses to token configuration.
    mapping(address => Token) public tokens;

    /// @notice The bank that manage to payout a won bet and collect a loss bet, and to interact with Referral program.
    IBank public bank;

    /// @notice Referral program contract.
    IReferral public referralProgram;

    /// @notice Emitted after the bank is set.
    /// @param bank Address of the bank contract.
    event SetBank(address bank);

    /// @notice Emitted after the referral program is set.
    /// @param referralProgram The referral program address.
    event SetReferralProgram(address referralProgram);

    /// @notice Emitted after the house edge is set for a token.
    /// @param token Address of the token.
    /// @param houseEdge House edge rate.
    event SetHouseEdge(address indexed token, uint16 houseEdge);

    /// @notice Emitted after the minimum bet amount is set for a token.
    /// @param token Address of the token.
    /// @param minBetAmount Minimum bet amount.
    event SetTokenMinBetAmount(address indexed token, uint256 minBetAmount);

    /// @notice Emitted after the bet amount transfer to the user failed.
    /// @param id The bet ID.
    /// @param amount Number of tokens failed to transfer.
    /// @param reason The reason provided by the external call.
    event BetAmountTransferFail(uint256 id, uint256 amount, string reason);

    /// @notice Emitted after the bet amount fee transfer to the bank failed.
    /// @param id The bet ID.
    /// @param amount Number of tokens failed to transfer.
    /// @param reason The reason provided by the external call.
    event BetAmountFeeTransferFail(uint256 id, uint256 amount, string reason);

    /// @notice Emitted after the bet profit transfer to the user failed.
    /// @param id The bet ID.
    /// @param amount Number of tokens failed to transfer.
    /// @param reason The reason provided by the external call.
    event BetProfitTransferFail(uint256 id, uint256 amount, string reason);

    /// @notice Emitted after the bet amount transfer to the bank failed.
    /// @param id The bet ID.
    /// @param amount Number of tokens failed to transfer.
    /// @param reason The reason provided by the external call.
    event BankCashInFail(uint256 id, uint256 amount, string reason);

    /// @notice Emitted after the bet amount ERC20 transfer to the bank failed.
    /// @param id The bet ID.
    /// @param amount Number of tokens failed to transfer.
    /// @param reason The reason provided by the external call.
    event BankTransferFail(uint256 id, uint256 amount, string reason);

    /// @notice Emitted after the bet amount is transfered to the user.
    /// @param id The bet ID.
    /// @param user Address of the gamer.
    /// @param amount Number of tokens refunded.
    event BetRefunded(uint256 id, address user, uint256 amount);

    /// @notice Emitted after the bet resolution cost refund to user failed.
    /// @param id The bet ID.
    /// @param user Address of the gamer.
    /// @param chainlinkVRFCost The bet resolution cost amount.
    event BetCostRefundFail(uint256 id, address user, uint256 chainlinkVRFCost);

    /// @notice Emitted after the token's VRF fees amount is transfered to the user.
    /// @param token Address of the token.
    /// @param amount Number of tokens refunded.
    event DistributeTokenVRFFees(address indexed token, uint256 amount);

    /// @notice Emitted after the token's VRF subscription ID is set.
    /// @param token Address of the token.
    /// @param subId Subscription ID.
    event SetTokenVRFSubId(address indexed token, uint64 subId);

    /// @notice Emitted after a token partner is set.
    /// @param token Address of the token.
    /// @param partner Address of the partner.
    event SetTokenPartner(address indexed token, address partner);

    /// @notice Insufficient bet amount.
    /// @param token Bet's token address.
    /// @param value Bet amount.
    error UnderMinBetAmount(address token, uint256 value);

    /// @notice Bet provided doesn't exist or was already resolved.
    /// @param id Bet ID.
    error NotPendingBet(uint256 id);

    /// @notice Bet isn't resolved yet.
    /// @param id Bet ID.
    error NotFulfilled(uint256 id);

    /// @notice House edge is capped at 4%.
    /// @param houseEdge House edge rate.
    error ExcessiveHouseEdge(uint16 houseEdge);

    /// @notice Token is not allowed.
    /// @param token Bet's token address.
    error ForbiddenToken(address token);

    /// @notice Chainlink price feed not working
    /// @param linkWei LINK/ETH price returned.
    error InvalidLinkWeiPrice(int256 linkWei);

    /// @notice The msg.value is not enough to cover Chainlink's fee.
    error WrongGasValueToCoverFee();

    /// @notice Reverting error when sender isn't allowed.
    error AccessDenied();

    /// @notice Modifier that checks that an account is allowed to interact.
    /// @param token The token address.
    modifier onlyTokenOwner(address token) {
        address partner = tokens[token].partner;
        if (
            partner == address(0)
                ? owner() != msg.sender
                : msg.sender != partner
        ) {
            revert AccessDenied();
        }
        _;
    }

    /// @notice Initialize contract's state variables and VRF Consumer.
    /// @param bankAddress The address of the bank.
    /// @param chainlinkCoordinatorAddress Address of the Chainlink VRF Coordinator.
    /// @param numRandomWords How many random words is needed to resolve a game's bet.
    constructor(
        address bankAddress,
        address referralProgramAddress,
        address chainlinkCoordinatorAddress,
        uint16 numRandomWords,
        address LINK_ETH_feedAddress
    ) VRFConsumerBaseV2(chainlinkCoordinatorAddress) {
        setBank(IBank(bankAddress));
        setReferralProgram(IReferral(referralProgramAddress));
        chainlinkCoordinator = IVRFCoordinatorV2(chainlinkCoordinatorAddress);
        _numRandomWords = numRandomWords;
        LINK_ETH_feed = AggregatorV3Interface(LINK_ETH_feedAddress);
    }

    /// @notice Sets the game house edge rate for a specific token.
    /// @param token Address of the token.
    /// @param houseEdge House edge rate.
    /// @dev The house edge rate couldn't exceed 4%.
    function _setHouseEdge(address token, uint16 houseEdge) internal onlyOwner {
        if (houseEdge > 400) {
            revert ExcessiveHouseEdge(houseEdge);
        }
        tokens[token].houseEdge = houseEdge;
        emit SetHouseEdge(token, houseEdge);
    }

    /// @notice Creates a new bet, request randomness to Chainlink, add the referrer,
    /// transfer the ERC20 tokens to the contract or refund the bet amount overflow if the bet amount exceed the maxBetAmount.
    /// @param token Address of the token.
    /// @param tokenAmount The number of tokens bet.
    /// @param multiplier The bet amount leverage determines the user's profit amount. 10000 = 100% = no profit.
    /// @param referrer Address of the referrer.
    /// @return A new Bet struct information.
    function _newBet(
        address token,
        uint256 tokenAmount,
        uint256 multiplier,
        address referrer
    ) internal whenNotPaused nonReentrant returns (Bet memory) {
        if (bank.isAllowedToken(token) == false) {
            revert ForbiddenToken(token);
        }

        address user = msg.sender;
        bool isGasToken = token == address(0);
        uint256 fee = isGasToken ? (msg.value - tokenAmount) : msg.value;
        uint256 betAmount = isGasToken ? msg.value - fee : tokenAmount;

        // Charge user for Chainlink VRF fee.
        {
            uint256 chainlinkVRFCost = getChainlinkVRFCost();
            if (fee < (chainlinkVRFCost - ((10 * chainlinkVRFCost) / 100))) {
                // 5% slippage.
                revert WrongGasValueToCoverFee();
            }
            tokens[token].VRFFees += fee;
        }

        // Bet amount is capped.
        {
            if (
                betAmount < 10000 wei || betAmount < tokens[token].minBetAmount
            ) {
                revert UnderMinBetAmount(token, betAmount);
            }

            uint256 maxBetAmount = bank.getMaxBetAmount(token, multiplier);
            if (betAmount > maxBetAmount) {
                if (isGasToken) {
                    Address.sendValue(payable(user), betAmount - maxBetAmount);
                }
                betAmount = maxBetAmount;
            }
        }

        // Create bet
        uint256 id = chainlinkCoordinator.requestRandomWords(
            chainlinkConfig.keyHash,
            tokens[token].VRFSubId == 0
                ? chainlinkConfig.subId
                : tokens[token].VRFSubId,
            chainlinkConfig.requestConfirmations,
            chainlinkConfig.callbackGasLimit,
            _numRandomWords
        );
        Bet memory newBet = Bet(
            false,
            payable(user),
            token,
            id,
            betAmount,
            block.number,
            0,
            fee
        );
        _userBets[user].push(id);
        bets[id] = newBet;

        // Add referrer
        if (
            referrer != address(0) &&
            _userBets[user].length == 1 &&
            !referralProgram.hasReferrer(user)
        ) {
            referralProgram.addReferrer(user, referrer);
        } else {
            referralProgram.updateReferrerActivity(user);
        }

        // If ERC20, transfer the tokens
        if (!isGasToken) {
            IERC20(token).safeTransferFrom(user, address(this), betAmount);
        }

        return newBet;
    }

    /// @notice Resolves the bet based on the game child contract result.
    /// In case bet is won, the bet amount minus the house edge is transfered to user from the game contract, and the profit is transfered to the user from the Bank.
    /// In case bet is lost, the bet amount is transfered to the Bank from the game contract.
    /// @param bet The Bet struct information.
    /// @param wins Whether the bet is winning.
    /// @param payout What should be sent to the user in case of a won bet. Payout = bet amount + profit amount.
    /// @return The payout amount.
    /// @dev Should not revert as it resolves the bet with the randomness.
    function _resolveBet(
        Bet storage bet,
        bool wins,
        uint256 payout
    ) internal returns (uint256) {
        address payable user = bet.user;
        if (bet.resolved == true || user == address(0)) {
            revert NotPendingBet(bet.id);
        }
        address token = bet.token;
        uint256 betAmount = bet.amount;
        bool isGasToken = bet.token == address(0);

        bet.resolved = true;

        // Check for the result
        if (wins) {
            uint256 profit = payout - betAmount;
            uint256 betAmountFee = _getFees(token, betAmount);
            uint256 profitFee = _getFees(token, profit);
            uint256 fee = betAmountFee + profitFee;

            payout -= fee;

            uint256 betAmountPayout = betAmount - betAmountFee;
            uint256 profitPayout = profit - profitFee;
            // Transfer the bet amount from the contract
            if (isGasToken) {
                (bool success, ) = user.call{value: betAmountPayout}("");
                if (!success) {
                    emit BetAmountTransferFail(
                        bet.id,
                        betAmount,
                        "Missing gas token funds"
                    );
                }
            } else {
                try
                    IERC20(token).transfer(user, betAmountPayout)
                {} catch Error(string memory reason) {
                    emit BetAmountTransferFail(bet.id, betAmountPayout, reason);
                }
                try
                    IERC20(token).transfer(address(bank), betAmountFee)
                {} catch Error(string memory reason) {
                    emit BetAmountFeeTransferFail(bet.id, betAmountFee, reason);
                }
            }

            // Transfer the payout from the bank
            try
                bank.payout{value: isGasToken ? betAmountFee : 0}(
                    user,
                    token,
                    profitPayout,
                    fee
                )
            {} catch Error(string memory reason) {
                emit BetProfitTransferFail(bet.id, profitPayout, reason);
            }
        } else {
            payout = 0;
            if (!isGasToken) {
                try
                    IERC20(token).transfer(address(bank), betAmount)
                {} catch Error(string memory reason) {
                    emit BankTransferFail(bet.id, betAmount, reason);
                }
            }
            try
                bank.cashIn{value: isGasToken ? betAmount : 0}(token, betAmount)
            {} catch Error(string memory reason) {
                emit BankCashInFail(bet.id, betAmount, reason);
            }
        }

        bet.payout = payout;
        return payout;
    }

    /// @notice Gets the list of the last user bets.
    /// @param user Address of the gamer.
    /// @param dataLength The amount of bets to return.
    /// @return A list of Bet.
    function _getLastUserBets(address user, uint256 dataLength)
        internal
        view
        returns (Bet[] memory)
    {
        uint256[] memory userBetsIds = _userBets[user];
        uint256 betsLength = userBetsIds.length;

        if (betsLength < dataLength) {
            dataLength = betsLength;
        }

        Bet[] memory userBets = new Bet[](dataLength);
        if (dataLength > 0) {
            uint256 userBetsIndex = 0;
            for (uint256 i = betsLength; i > betsLength - dataLength; i--) {
                userBets[userBetsIndex] = bets[userBetsIds[i - 1]];
                userBetsIndex++;
            }
        }

        return userBets;
    }

    /// @notice Calculates the amount's fee based on the house edge.
    /// @param token Address of the token.
    /// @param amount From which the fee amount will be calculated.
    /// @return The fee amount.
    function _getFees(address token, uint256 amount)
        internal
        view
        returns (uint256)
    {
        return (tokens[token].houseEdge * amount) / 10000;
    }

    /// @notice Sets the Bank contract.
    /// @param _bank Address of the Bank contract.
    function setBank(IBank _bank) public onlyOwner {
        bank = _bank;
        emit SetBank(address(_bank));
    }

    /// @notice Sets the new referral program.
    /// @param _referralProgram The referral program address.
    function setReferralProgram(IReferral _referralProgram) public onlyOwner {
        referralProgram = _referralProgram;
        emit SetReferralProgram(address(referralProgram));
    }

    /// @notice Pauses the contract to disable new bets.
    function pause() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }

    /// @notice Sets the Chainlink VRF V2 configuration.
    /// @param subId Subscription ID.
    /// @param callbackGasLimit How much gas you would like in your callback to do work with the random words provided.
    /// @param requestConfirmations How many confirmations the Chainlink node should wait before responding.
    /// @param keyHash Hash of the public key used to verify the VRF proof.
    function setChainlinkConfig(
        uint64 subId,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bytes32 keyHash
    ) external onlyOwner {
        chainlinkConfig.subId = subId;
        chainlinkConfig.callbackGasLimit = callbackGasLimit;
        chainlinkConfig.requestConfirmations = requestConfirmations;
        chainlinkConfig.keyHash = keyHash;
    }

    /// @notice Withdraws remaining tokens.
    /// @param token Address of the token.
    /// @param amount Number of tokens.
    /// @dev Useful in case some transfers failed during the bet resolution callback.
    function inCaseTokensGetStuck(address token, uint256 amount)
        external
        onlyOwner
    {
        if (token == address(0)) {
            Address.sendValue(payable(msg.sender), amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /// @notice Changes the token's partner address.
    /// @param token Address of the token.
    /// @param partner Address of the partner.
    function setTokenPartner(address token, address partner)
        external
        onlyTokenOwner(token)
    {
        tokens[token].partner = partner;
        emit SetTokenPartner(token, partner);
    }

    /// @notice Sets the minimum bet amount for a specific token.
    /// @param token Address of the token.
    /// @param tokenMinBetAmount Minimum bet amount.
    function setTokenMinBetAmount(address token, uint256 tokenMinBetAmount)
        external
        onlyTokenOwner(token)
    {
        tokens[token].minBetAmount = tokenMinBetAmount;
        emit SetTokenMinBetAmount(token, tokenMinBetAmount);
    }

    /// @notice Sets the Chainlink VRF subscription ID for a specific token.
    /// @param token Address of the token.
    /// @param subId Subscription ID.
    function setTokenVRFSubId(address token, uint64 subId)
        external
        onlyTokenOwner(token)
    {
        tokens[token].VRFSubId = subId;
        emit SetTokenVRFSubId(token, subId);
    }

    /// @notice Distributes the token's collected Chainlink fees.
    /// @param token Address of the token.
    function withdrawTokensVRFFees(address token)
        external
        onlyTokenOwner(token)
    {
        uint256 tokenChainlinkFees = tokens[token].VRFFees;
        if (tokenChainlinkFees != 0) {
            tokens[token].VRFFees = 0;
            Address.sendValue(payable(msg.sender), tokenChainlinkFees);
            emit DistributeTokenVRFFees(token, tokenChainlinkFees);
        }
    }

    /// @notice Refunds the bet to the user if the Chainlink VRF callback failed.
    /// @param id The Bet ID.
    function refundBet(uint256 id) external {
        Bet storage bet = bets[id];
        if (bet.resolved == true) {
            revert NotPendingBet(id);
        } else if (block.number < bet.blockNumber + 30) {
            revert NotFulfilled(id);
        }

        bet.resolved = true;
        bet.payout = bet.amount;

        if (bet.token == address(0)) {
            Address.sendValue(bet.user, bet.amount);
        } else {
            IERC20(bet.token).safeTransfer(bet.user, bet.amount);
        }
        emit BetRefunded(id, bet.user, bet.amount);

        uint256 chainlinkVRFCost = bet.vrfCost;
        if (
            tokens[bet.token].VRFFees >= chainlinkVRFCost &&
            address(this).balance >= chainlinkVRFCost
        ) {
            tokens[bet.token].VRFFees -= chainlinkVRFCost;
            Address.sendValue(bet.user, chainlinkVRFCost);
        } else {
            emit BetCostRefundFail(id, bet.user, chainlinkVRFCost);
        }
    }

    /// @notice Returns the amount of ETH that should be passed to the wager transaction
    /// to cover Chainlink VRF fee.
    /// @return The bet resolution cost amount.
    function getChainlinkVRFCost() public view returns (uint256) {
        (, int256 weiPerUnitLink, , , ) = LINK_ETH_feed.latestRoundData();
        if (weiPerUnitLink <= 0) {
            revert InvalidLinkWeiPrice(weiPerUnitLink);
        }
        // Get Chainlink VRF v2 fee amount.
        (
            uint32 fulfillmentFlatFeeLinkPPMTier1,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = chainlinkCoordinator.getFeeConfig();
        // 115000 gas is the average Verification gas of Chainlink VRF.
        return
            (tx.gasprice * (115000 + chainlinkConfig.callbackGasLimit)) +
            ((1e12 *
                uint256(fulfillmentFlatFeeLinkPPMTier1) *
                uint256(weiPerUnitLink)) / 1e18);
    }
}
