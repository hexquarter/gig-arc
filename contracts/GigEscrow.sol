// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IGigEscrow} from "./GigRegistry.sol";

contract GigEscrow is IGigEscrow, Initializable, UUPSUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct EscrowEntry {
        address client;
        address freelancer;
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 refundedAmount;
        bool initialized;
    }

    /// @custom:storage-location erc7201:gigescrow.v1
    struct GigEscrowStorage {
        mapping(uint256 => EscrowEntry) escrows;
        address usdc;
        address gigRegistry;
        address gigTreasury;
        uint256 feeBps;
    }

    // Pre-computed: keccak256(abi.encode(uint256(keccak256("gigescrow.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GIGESCROW_STORAGE_SLOT =
        0x1d243e5684f41fc4b936f9587d4c9dd51b1b376a71dcede07692820cc6f42d00;

    event EscrowLocked(uint256 indexed jobId, uint256 amount);
    event PaymentReleased(uint256 indexed jobId, uint256 net, uint256 fee);
    event EscrowRefunded(uint256 indexed jobId, uint256 amount);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed treasury);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    modifier onlyRegistry() {
        if (msg.sender != _getStorage().gigRegistry) revert("Only registry");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdc,
        address _gigRegistry,
        address _gigTreasury,
        uint256 _feeBps,
        address _owner
    ) external initializer {
        if (_usdc == address(0)) revert("Zero usdc");
        if (_gigRegistry == address(0)) revert("Zero registry");
        if (_gigTreasury == address(0)) revert("Zero treasury");
        if (_owner == address(0)) revert("Zero owner");
        if (_feeBps > 1000) revert("Fee too high");

        __Pausable_init();
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        GigEscrowStorage storage $ = _getStorage();
        $.usdc = _usdc;
        $.gigRegistry = _gigRegistry;
        $.gigTreasury = _gigTreasury;
        $.feeBps = _feeBps;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function lockEscrow(
        uint256 jobId,
        address client,
        address freelancer,
        uint256 amount
    ) external onlyRegistry whenNotPaused nonReentrant {
        if (client == address(0)) revert("Zero client");
        if (freelancer == address(0)) revert("Zero freelancer");
        if (amount == 0) revert("Zero amount");

        GigEscrowStorage storage $ = _getStorage();
        EscrowEntry storage entry = $.escrows[jobId];

        if (entry.initialized) revert("Escrow exists");

        IERC20 usdcToken = IERC20($.usdc);
        uint256 preBalance = usdcToken.balanceOf(address(this));
        usdcToken.safeTransferFrom(client, address(this), amount);
        uint256 postBalance = usdcToken.balanceOf(address(this));

        if (postBalance - preBalance != amount) revert("Fee-on-transfer token");

        entry.client = client;
        entry.freelancer = freelancer;
        entry.totalAmount = amount;
        entry.initialized = true;

        emit EscrowLocked(jobId, amount);
    }

    function releasePayment(
        uint256 jobId,
        uint256 amount,
        address freelancer
    ) external onlyRegistry whenNotPaused nonReentrant {
        if (freelancer == address(0)) revert("Zero freelancer");

        GigEscrowStorage storage $ = _getStorage();
        EscrowEntry storage entry = $.escrows[jobId];

        if (!entry.initialized) revert("Escrow missing");
        if (freelancer != entry.freelancer) revert("Freelancer mismatch");
        if (entry.releasedAmount + entry.refundedAmount + amount > entry.totalAmount) revert("Insufficient escrow");

        uint256 fee = (amount * $.feeBps) / 10_000;
        uint256 net = amount - fee;

        entry.releasedAmount += amount;

        IERC20 usdcToken = IERC20($.usdc);
        usdcToken.safeTransfer($.gigTreasury, fee);
        usdcToken.safeTransfer(freelancer, net);

        emit PaymentReleased(jobId, net, fee);
    }

    function refund(uint256 jobId, address client) external onlyRegistry whenNotPaused nonReentrant {
        if (client == address(0)) revert("Zero client");

        GigEscrowStorage storage $ = _getStorage();
        EscrowEntry storage entry = $.escrows[jobId];

        if (!entry.initialized) revert("Escrow missing");
        if (client != entry.client) revert("Client mismatch");

        uint256 remaining = entry.totalAmount - entry.releasedAmount - entry.refundedAmount;
        if (remaining == 0) revert("Nothing to refund");

        entry.refundedAmount += remaining;

        IERC20($.usdc).safeTransfer(client, remaining);

        emit EscrowRefunded(jobId, remaining);
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > 1000) revert("Fee too high");

        GigEscrowStorage storage $ = _getStorage();
        uint256 oldBps = $.feeBps;
        $.feeBps = _feeBps;

        emit FeeBpsUpdated(oldBps, _feeBps);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert("Zero treasury");

        _getStorage().gigTreasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert("Zero registry");

        GigEscrowStorage storage $ = _getStorage();
        address oldRegistry = $.gigRegistry;
        $.gigRegistry = _registry;

        emit RegistryUpdated(oldRegistry, _registry);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        GigEscrowStorage storage $ = _getStorage();

        if (token == address(0)) revert("Zero token");
        if (to == address(0)) revert("Zero to");
        if (token == $.usdc) revert("USDC not rescuable");

        IERC20(token).safeTransfer(to, amount);
    }

    function getEscrow(uint256 jobId) external view returns (EscrowEntry memory) {
        return _getStorage().escrows[jobId];
    }

    function usdc() external view returns (address) {
        return _getStorage().usdc;
    }

    function gigRegistry() external view returns (address) {
        return _getStorage().gigRegistry;
    }

    function gigTreasury() external view returns (address) {
        return _getStorage().gigTreasury;
    }

    function feeBps() external view returns (uint256) {
        return _getStorage().feeBps;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Disabled");
    }

    /// @dev v1: upgrade authority is owner (multisig). v2 should add a TimelockController for delayed upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _getStorage() private pure returns (GigEscrowStorage storage $) {
        assembly {
            $.slot := GIGESCROW_STORAGE_SLOT
        }
    }
}
