// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract GigTreasury is Initializable, UUPSUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:gigtreasury.v1
    struct GigTreasuryStorage {
        address usdc;
    }

    // Pre-computed: keccak256(abi.encode(uint256(keccak256("gigtreasury.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GIGTREASURY_STORAGE_SLOT =
        0x47b6dfdb45e288c8213fbb79714bac8e2ef37283393e11f80d18d75bc1248c00;

    event TreasuryWithdrawal(address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc, address _owner) external initializer {
        if (_usdc == address(0)) revert("Zero usdc");
        if (_owner == address(0)) revert("Zero owner");

        __Pausable_init();
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        GigTreasuryStorage storage $ = _getStorage();
        $.usdc = _usdc;
    }

    function usdc() external view returns (address) {
        return _getStorage().usdc;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw(address to, uint256 amount) external onlyOwner whenNotPaused {
        if (to == address(0)) revert("Zero to");

        IERC20(_getStorage().usdc).safeTransfer(to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    function withdrawAll(address to) external onlyOwner whenNotPaused {
        if (to == address(0)) revert("Zero to");

        address usdcToken = _getStorage().usdc;
        uint256 amount = IERC20(usdcToken).balanceOf(address(this));
        IERC20(usdcToken).safeTransfer(to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        GigTreasuryStorage storage $ = _getStorage();

        if (token == address(0)) revert("Zero token");
        if (to == address(0)) revert("Zero to");
        if (token == $.usdc) revert("Use withdraw");

        IERC20(token).safeTransfer(to, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Disabled");
    }

    /// @dev v1: upgrade authority is owner (multisig). v2 should add a TimelockController for delayed upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _getStorage() private pure returns (GigTreasuryStorage storage $) {
        assembly {
            $.slot := GIGTREASURY_STORAGE_SLOT
        }
    }
}
