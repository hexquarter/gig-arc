// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IGigReputation} from "./GigRegistry.sol";

contract GigReputation is IGigReputation, Initializable, UUPSUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable {
    struct ReputationRecord {
        uint256 jobsCompleted;
        uint256 jobsCancelled;
        uint256 totalUsdcEarned;
        uint256 totalUsdcSpent;
        uint256 score;
    }

    /// @custom:storage-location erc7201:gigreputation.v1
    struct GigReputationStorage {
        mapping(address => ReputationRecord) records;
        address gigRegistry;
    }

    // Pre-computed: keccak256(abi.encode(uint256(keccak256("gigreputation.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GIGREPUTATION_STORAGE_SLOT =
        0xdc4d63c9f5f6e074d7c720e14e239c21939475fd68424da07303e1ef562b9200;

    event ReputationUpdated(address indexed user, uint256 score);
    event RegistrySet(address indexed registry);

    modifier onlyRegistry() {
        if (msg.sender != _getStorage().gigRegistry) revert("Only registry");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert("Zero owner");

        __Pausable_init();
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert("Zero registry");

        _getStorage().gigRegistry = _registry;
        emit RegistrySet(_registry);
    }

    function gigRegistry() external view returns (address) {
        return _getStorage().gigRegistry;
    }

    function recordCompletion(address client, address freelancer, uint256 usdcAmount) external onlyRegistry whenNotPaused {
        if (client == address(0)) revert("Zero client");
        if (freelancer == address(0)) revert("Zero freelancer");

        GigReputationStorage storage $ = _getStorage();

        ReputationRecord storage clientRecord = $.records[client];
        ReputationRecord storage freelancerRecord = $.records[freelancer];

        clientRecord.jobsCompleted += 1;
        clientRecord.totalUsdcSpent += usdcAmount;
        clientRecord.score = _computeScore(clientRecord);

        freelancerRecord.jobsCompleted += 1;
        freelancerRecord.totalUsdcEarned += usdcAmount;
        freelancerRecord.score = _computeScore(freelancerRecord);

        emit ReputationUpdated(client, clientRecord.score);
        emit ReputationUpdated(freelancer, freelancerRecord.score);
    }

    function recordCancellation(address client, address freelancer) external onlyRegistry whenNotPaused {
        if (client == address(0)) revert("Zero client");
        if (freelancer == address(0)) revert("Zero freelancer");

        GigReputationStorage storage $ = _getStorage();

        ReputationRecord storage clientRecord = $.records[client];
        ReputationRecord storage freelancerRecord = $.records[freelancer];

        clientRecord.jobsCancelled += 1;
        clientRecord.score = _computeScore(clientRecord);

        freelancerRecord.jobsCancelled += 1;
        freelancerRecord.score = _computeScore(freelancerRecord);

        emit ReputationUpdated(client, clientRecord.score);
        emit ReputationUpdated(freelancer, freelancerRecord.score);
    }

    function getRecord(address user) external view returns (ReputationRecord memory) {
        return _getStorage().records[user];
    }

    function getScore(address user) external view returns (uint256) {
        return _getStorage().records[user].score;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Disabled");
    }

    /// @dev v1: upgrade authority is owner (multisig). v2 should add a TimelockController for delayed upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _computeScore(ReputationRecord storage record) private view returns (uint256) {
        uint256 positive = (record.jobsCompleted * 100) + (record.totalUsdcEarned / 1e6);
        uint256 penalty = record.jobsCancelled * 50;
        return positive >= penalty ? positive - penalty : 0;
    }

    function _getStorage() private pure returns (GigReputationStorage storage $) {
        assembly {
            $.slot := GIGREPUTATION_STORAGE_SLOT
        }
    }
}
