// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.1;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
// import "hardhat/console.sol";

/**
 * @title PostageStaking contract
 * @author The Swarm Authors
 * @dev The postage stamp contracts allows users to create and manage postage stamp batches.
 */
contract StakeRegistry is AccessControl, Pausable {

    /**
     * @dev Emitted when a new batch is created.
     */
    event StakeUpdated(
        bytes32 indexed overlay,
        uint256 stakeAmount,
        address owner,
        uint256 lastUpdatedBlock
    );

    event StakeSlashed(bytes32 slashed, uint256 amount);
    event StakeFrozen(bytes32 slashed, uint256 time);

    struct Stake {
        //
        bytes32 overlay;
        //
        uint256 stakeAmount;
        //
        uint256 pendingStakeIncrease;
        //
        address owner;
        //
        uint256 lastUpdatedBlockNumber;
    }

    // The role allowed to pause
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    // The role allowed to freeze and slash entries
    bytes32 public constant REDISTRIBUTOR_ROLE = keccak256("REDISTRIBUTOR_ROLE");

    uint64 NetworkId;

    // Associate every stake id with overlay data.
    mapping(bytes32 => Stake) public stakes;

    address public bzzToken;

    uint256 public pot;

    /**
     * @param _bzzToken The ERC20 token address to reference in this contract.
     */
    constructor(address _bzzToken, uint64 _NetworkId) {
        NetworkId = _NetworkId;
        bzzToken = _bzzToken;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(PAUSER_ROLE, msg.sender);
    }

    function overlayNotFrozen(bytes32 overlay) internal view returns (bool) {
        return stakes[overlay].lastUpdatedBlockNumber < block.number;
    }

    function stakeOfOverlay(bytes32 overlay) public view returns (uint256) {
        return stakes[overlay].stakeAmount;
    }

    function usableStakeOfOverlay(bytes32 overlay, uint256 time) public view returns (uint256) {
        if (overlayNotFrozen(overlay)) {
            return (
                block.number > stakes[overlay].lastUpdatedBlockNumber + time ? 
                    stakes[overlay].stakeAmount + stakes[overlay].pendingStakeIncrease : 
                    stakes[overlay].stakeAmount
            );
        } else {
            return 0;
        }
    }

    function lastUpdatedBlockNumberOfOverlay(bytes32 overlay) public view returns(uint256) {
        return stakes[overlay].lastUpdatedBlockNumber;
    }

    function ownerOfOverlay(bytes32 overlay) public view returns (address) {
        return stakes[overlay].owner;
    }

    function reverse(uint64 input) internal pure returns (uint64 v) {
        v = input;

        // swap bytes
        v = ((v & 0xFF00FF00FF00FF00) >> 8) |
            ((v & 0x00FF00FF00FF00FF) << 8);

        // swap 2-byte long pairs
        v = ((v & 0xFFFF0000FFFF0000) >> 16) |
            ((v & 0x0000FFFF0000FFFF) << 16);

        // swap 4-byte long pairs
        v = (v >> 32) | (v << 32);
    }

    /**
     * @notice Create a new stake or update an existing one.
     * @dev At least `_initialBalancePerChunk*2^depth` number of tokens need to be preapproved for this contract.
     * @param _owner eth address used for overlay calculation
     * @param nonce used for overlay calculation
     * @param amount deposited amount
     */
    function depositStake(
        address _owner,
        bytes32 nonce,
        uint256 amount
    ) external whenNotPaused {
        require(_owner != address(0), "owner cannot be the zero address");

        bytes32 overlay = keccak256(abi.encodePacked(_owner, reverse(NetworkId), nonce));

        Stake storage stake = stakes[overlay];

        if (stake.owner != address(0)) {
            require(overlayNotFrozen(overlay), "overlay currently frozen");
        } else {
            stake.overlay = overlay;
            stake.owner = _owner;
        }

        stake.pendingStakeIncrease += amount;
        stake.lastUpdatedBlockNumber = block.number;

        require(ERC20(bzzToken).transferFrom(msg.sender, address(this), amount), "failed transfer");

        emit StakeUpdated(overlay, stake.stakeAmount + stake.pendingStakeIncrease, _owner, block.number);
    }

    /**
     * @notice withdraw stake when staking contract paused
     * @dev can only be called by the owner specifying the associated overlay
     * @param overlay the overlay selected
     * @param amount stake amount to be withdrawn
     */
    function withdrawFromStake(bytes32 overlay, uint256 amount) external whenPaused {
        require(stakes[overlay].owner == msg.sender, "only owner can withdraw stake");
        uint256 withDrawLimit = amount;
        uint256 maxWithDrawLimit = stakes[overlay].stakeAmount + stakes[overlay].pendingStakeIncrease;

        if (amount > maxWithDrawLimit) {
            withDrawLimit = maxWithDrawLimit;
        }

        if (withDrawLimit < maxWithDrawLimit) {
            stakes[overlay].stakeAmount = 0;
            stakes[overlay].pendingStakeIncrease = maxWithDrawLimit - withDrawLimit;
            stakes[overlay].lastUpdatedBlockNumber = block.number;
            require(ERC20(bzzToken).transfer(msg.sender, withDrawLimit), "failed withdrawal");
        } else {
            delete stakes[overlay];
            require(ERC20(bzzToken).transfer(msg.sender, withDrawLimit), "failed withdrawal");
        }
    }

    /**
     * @notice freeze an existing stake
     * @dev can only be called by the redistributor
     * @param overlay the overlay selected
     * @param time penalty length in blocknumbers
     */
    function freezeDeposit(bytes32 overlay, uint256 time) external {
        require(hasRole(REDISTRIBUTOR_ROLE, msg.sender), "only redistributor can freeze stake");
        require(stakes[overlay].owner != address(0), "overlay does not exist");

        emit StakeFrozen(overlay, time);
        stakes[overlay].lastUpdatedBlockNumber = block.number + time;
    }

    /**
     * @notice slash and redistribute an existing stake
     * @dev can only be called by the redistributor
     * @param overlay the overlay selected
     * @param amount the amount to be slashed
     *
     */
    function slashDeposit(bytes32 overlay, uint256 amount) external {
        require(hasRole(REDISTRIBUTOR_ROLE, msg.sender), "only redistributor can slash stake");
        require(stakes[overlay].owner != address(0), "overlay does not exist");

        emit StakeSlashed(overlay, amount);

        if ( stakes[overlay].stakeAmount > amount ) {
            stakes[overlay].stakeAmount -= amount;
            stakes[overlay].lastUpdatedBlockNumber = block.number;
        } else {
            delete stakes[overlay];
        }
    }

    /**
     * @notice Etches a pending stake increase to stakeAmount for the overlay.
     * @dev can only be called by the redistributor
     * @param overlay The overlay to add the pending stake increase to.
     * @param minDelay The minimum delay in blocks to wait before the pending stake increase can be applied.
     */
    function etchPendingStake(bytes32 overlay, uint256 minDelay) external {
        require(hasRole(REDISTRIBUTOR_ROLE, msg.sender), "only redistributor can add pending stake");
        require(overlayNotFrozen(overlay), "overlay frozen");
        require(block.number > stakes[overlay].lastUpdatedBlockNumber + minDelay, "too soon");

        uint256 pendingStakeIncrease = stakes[overlay].pendingStakeIncrease;
        stakes[overlay].pendingStakeIncrease = 0;
        stakes[overlay].stakeAmount += pendingStakeIncrease;
    }

    /**
     * @notice Pause the contract. The contract is provably stopped by renouncing the pauser role and the admin role 
     *         after pausing
     * @dev can only be called by the pauser when not paused
     */
    function pause() public {
        require(hasRole(PAUSER_ROLE, msg.sender), "only pauser can pause the contract");
        _pause();
    }

    /**
     * @notice Unpause the contract.
     * @dev can only be called by the pauser when paused
     */
    function unPause() public {
        require(hasRole(PAUSER_ROLE, msg.sender), "only pauser can unpause the contract");
        _unpause();
    }

}
