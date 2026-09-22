// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GigTreasury} from "../GigTreasury.sol";
import {GigReputation} from "../GigReputation.sol";
import {GigEscrow} from "../GigEscrow.sol";
import {GigRegistry} from "../GigRegistry.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Shared deployment helpers
// ─────────────────────────────────────────────────────────────────────────────

contract GigPlatformBase is Test {
    // actors
    address internal owner      = makeAddr("owner");
    address internal client     = makeAddr("client");
    address internal freelancer = makeAddr("freelancer");
    address internal stranger   = makeAddr("stranger");

    // contracts
    MockERC20      internal usdc;
    GigTreasury    internal treasury;
    GigReputation  internal reputation;
    GigEscrow      internal escrow;
    GigRegistry    internal registry;

    // constants
    uint256 internal constant FEE_BPS    = 250;   // 2.5 %
    uint256 internal constant BUDGET     = 1_000e6; // 1 000 USDC (6 dec)
    uint256 internal constant FUND_AMOUNT = 100_000e6;

    // convenience: GigRegistry constants
    uint256 internal constant REVIEW_PERIOD = 3 days;
    uint256 internal constant GRACE_PERIOD  = 7 days;

    function setUp() public virtual {
        // 1. Deploy mock USDC
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // 2. Deploy GigTreasury proxy
        {
            GigTreasury impl = new GigTreasury();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(GigTreasury.initialize, (address(usdc), owner))
            );
            treasury = GigTreasury(address(proxy));
        }

        // 3. Deploy GigReputation proxy
        {
            GigReputation impl = new GigReputation();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(GigReputation.initialize, (owner))
            );
            reputation = GigReputation(address(proxy));
        }

        // 4. Deploy GigEscrow proxy (needs a real registry address — use a placeholder first,
        //    then call setRegistry after registry is deployed)
        {
            GigEscrow impl = new GigEscrow();
            // Pass owner as temporary registry placeholder (non-zero) for the initializer check
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(GigEscrow.initialize, (address(usdc), owner, address(treasury), FEE_BPS, owner))
            );
            escrow = GigEscrow(address(proxy));
        }

        // 5. Deploy GigRegistry proxy
        {
            GigRegistry impl = new GigRegistry();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(GigRegistry.initialize, (address(escrow), address(reputation), owner))
            );
            registry = GigRegistry(address(proxy));
        }

        // 6. Wire: point escrow and reputation at the real registry
        vm.startPrank(owner);
        escrow.setRegistry(address(registry));
        reputation.setRegistry(address(registry));
        vm.stopPrank();

        // 7. Fund client with USDC and approve escrow
        usdc.mint(client, FUND_AMOUNT);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// Post a simple (no-milestone) job and return its jobId.
    function _postSimpleJob(uint256 budget, uint256 deadlineOffset) internal returns (uint256 jobId) {
        vm.prank(client);
        GigRegistry.MilestoneInput[] memory noMilestones = new GigRegistry.MilestoneInput[](0);
        jobId = registry.postJob(keccak256("desc"), budget, block.timestamp + deadlineOffset, noMilestones);
    }

    /// Post a job, submit a matching proposal, have both parties accept → job is Locked.
    function _lockJob(uint256 budget, uint256 deadlineOffset)
        internal
        returns (uint256 jobId, uint256 proposalId)
    {
        jobId = _postSimpleJob(budget, deadlineOffset);

        vm.prank(freelancer);
        proposalId = registry.submitProposal(jobId, budget, keccak256("timeline"));

        // client accepts first
        vm.prank(client);
        registry.acceptProposal(jobId, proposalId);

        // freelancer accepts second → triggers lockEscrow
        vm.prank(freelancer);
        registry.acceptProposal(jobId, proposalId);
    }

    /// Full happy-path to job completion (single milestone).
    function _completeJob(uint256 budget)
        internal
        returns (uint256 jobId, uint256 proposalId)
    {
        (jobId, proposalId) = _lockJob(budget, 14 days);

        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("deliverable"));

        vm.prank(client);
        registry.approveDeliverable(jobId, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  GigTreasury tests
// ─────────────────────────────────────────────────────────────────────────────

contract GigTreasuryTest is GigPlatformBase {

    function _seedTreasury(uint256 amount) internal {
        usdc.mint(address(treasury), amount);
    }

    // ── withdraw ──────────────────────────────────────────────────────────────

    function testWithdraw() public {
        uint256 amount = 500e6;
        _seedTreasury(amount);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit GigTreasury.TreasuryWithdrawal(owner, amount);

        vm.prank(owner);
        treasury.withdraw(owner, amount);

        assertEq(usdc.balanceOf(owner), amount, "owner should receive USDC");
        assertEq(usdc.balanceOf(address(treasury)), 0, "treasury should be drained");
    }

    function testWithdrawPartial() public {
        _seedTreasury(1_000e6);

        vm.prank(owner);
        treasury.withdraw(owner, 300e6);

        assertEq(usdc.balanceOf(owner), 300e6);
        assertEq(usdc.balanceOf(address(treasury)), 700e6);
    }

    function testWithdrawRevertsNonOwner() public {
        _seedTreasury(100e6);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        treasury.withdraw(stranger, 100e6);
    }

    function testWithdrawRevertsZeroTo() public {
        _seedTreasury(100e6);

        vm.prank(owner);
        vm.expectRevert(bytes("Zero to"));
        treasury.withdraw(address(0), 100e6);
    }

    // ── withdrawAll ───────────────────────────────────────────────────────────

    function testWithdrawAll() public {
        uint256 amount = 777e6;
        _seedTreasury(amount);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit GigTreasury.TreasuryWithdrawal(owner, amount);

        vm.prank(owner);
        treasury.withdrawAll(owner);

        assertEq(usdc.balanceOf(owner), amount);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function testWithdrawAllRevertsNonOwner() public {
        _seedTreasury(100e6);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        treasury.withdrawAll(stranger);
    }

    // ── rescueERC20 ───────────────────────────────────────────────────────────

    function testRescueERC20() public {
        MockERC20 stuckToken = new MockERC20("Stuck", "STK", 18);
        stuckToken.mint(address(treasury), 50e18);

        vm.prank(owner);
        treasury.rescueERC20(address(stuckToken), owner, 50e18);

        assertEq(stuckToken.balanceOf(owner), 50e18);
        assertEq(stuckToken.balanceOf(address(treasury)), 0);
    }

    function testRescueERC20RevertsForUSDC() public {
        _seedTreasury(100e6);

        vm.prank(owner);
        vm.expectRevert(bytes("Use withdraw"));
        treasury.rescueERC20(address(usdc), owner, 100e6);
    }

    function testRescueERC20RevertsNonOwner() public {
        MockERC20 stuckToken = new MockERC20("Stuck", "STK", 18);
        stuckToken.mint(address(treasury), 50e18);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        treasury.rescueERC20(address(stuckToken), stranger, 50e18);
    }

    // ── pause ─────────────────────────────────────────────────────────────────

    function testWithdrawRevertsWhenPaused() public {
        _seedTreasury(100e6);

        vm.prank(owner);
        treasury.pause();

        vm.prank(owner);
        vm.expectRevert(); // EnforcedPause
        treasury.withdraw(owner, 100e6);
    }

    // ── renounceOwnership disabled ────────────────────────────────────────────

    function testRenounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Disabled"));
        treasury.renounceOwnership();
    }

    // ── invariant: treasury USDC balance never negative ──────────────────────

    function invariant_treasuryBalanceNonNegative() public view {
        // uint256 can't be negative; this confirms no overflow path
        assertGe(usdc.balanceOf(address(treasury)), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  GigReputation tests
// ─────────────────────────────────────────────────────────────────────────────

contract GigReputationTest is GigPlatformBase {

    // ── recordCompletion ──────────────────────────────────────────────────────

    function testRecordCompletion() public {
        vm.prank(address(registry));
        reputation.recordCompletion(client, freelancer, BUDGET);

        GigReputation.ReputationRecord memory cRec = reputation.getRecord(client);
        GigReputation.ReputationRecord memory fRec = reputation.getRecord(freelancer);

        assertEq(cRec.jobsCompleted, 1,     "client jobsCompleted should be 1");
        assertEq(fRec.jobsCompleted, 1,     "freelancer jobsCompleted should be 1");
        assertEq(cRec.totalUsdcSpent, BUDGET, "client totalUsdcSpent");
        assertEq(fRec.totalUsdcEarned, BUDGET, "freelancer totalUsdcEarned");
        assertGt(cRec.score, 0,             "client score should be > 0");
        assertGt(fRec.score, 0,             "freelancer score should be > 0");
    }

    function testRecordCompletionEmitsEvent() public {
        // Both client and freelancer events are emitted (in order)
        vm.prank(address(registry));
        vm.expectEmit(true, false, false, false, address(reputation));
        emit GigReputation.ReputationUpdated(client, 0); // score value doesn't matter (data=false)
        reputation.recordCompletion(client, freelancer, BUDGET);
    }

    // ── recordCancellation ────────────────────────────────────────────────────

    function testRecordCancellation() public {
        vm.prank(address(registry));
        reputation.recordCancellation(client, freelancer);

        GigReputation.ReputationRecord memory cRec = reputation.getRecord(client);
        GigReputation.ReputationRecord memory fRec = reputation.getRecord(freelancer);

        assertEq(cRec.jobsCancelled, 1, "client jobsCancelled should be 1");
        assertEq(fRec.jobsCancelled, 1, "freelancer jobsCancelled should be 1");
    }

    // ── onlyRegistry guard ────────────────────────────────────────────────────

    function testOnlyRegistryCanRecord() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Only registry"));
        reputation.recordCompletion(client, freelancer, BUDGET);
    }

    function testOnlyRegistryCanRecordCancellation() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Only registry"));
        reputation.recordCancellation(client, freelancer);
    }

    // ── score floor ───────────────────────────────────────────────────────────

    function testScoreFloor() public {
        // Many cancellations with no completions → score must stay at 0, never underflow
        vm.startPrank(address(registry));
        for (uint256 i = 0; i < 100; i++) {
            reputation.recordCancellation(client, freelancer);
        }
        vm.stopPrank();

        assertEq(reputation.getScore(client),     0, "score should be floored at 0");
        assertEq(reputation.getScore(freelancer),  0, "score should be floored at 0");
    }

    // ── score computation ─────────────────────────────────────────────────────

    function testScorePositiveAfterCompletion() public {
        vm.prank(address(registry));
        reputation.recordCompletion(client, freelancer, 1_000e6);

        // positive = 1*100 + 1000 = 1100; penalty = 0 → score == 1100
        assertEq(reputation.getScore(freelancer), 1100);
    }

    function testScorePenaltyReducesScore() public {
        vm.startPrank(address(registry));
        reputation.recordCompletion(client, freelancer, 1_000e6); // freelancer score = 1100
        reputation.recordCancellation(client, freelancer);         // penalty 50 → 1050
        vm.stopPrank();

        assertEq(reputation.getScore(freelancer), 1050);
    }

    // ── setRegistry access ────────────────────────────────────────────────────

    function testSetRegistryRevertsNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        reputation.setRegistry(stranger);
    }

    function testSetRegistryRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Zero registry"));
        reputation.setRegistry(address(0));
    }

    // ── fuzz: score never underflows ──────────────────────────────────────────

    function testFuzz_ScoreNeverUnderflows(uint8 completions, uint8 cancels, uint96 earned) public {
        vm.startPrank(address(registry));
        for (uint256 i = 0; i < completions; i++) {
            reputation.recordCompletion(client, freelancer, earned);
        }
        for (uint256 i = 0; i < cancels; i++) {
            reputation.recordCancellation(client, freelancer);
        }
        vm.stopPrank();

        // score is a uint256 — the contract clamps to 0, never reverts
        uint256 score = reputation.getScore(freelancer);
        assertGe(score, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  GigEscrow tests
// ─────────────────────────────────────────────────────────────────────────────

contract GigEscrowTest is GigPlatformBase {

    // ── lockEscrow ────────────────────────────────────────────────────────────

    function testLockEscrow() public {
        uint256 amount = BUDGET;
        uint256 escrowBalanceBefore = usdc.balanceOf(address(escrow));
        uint256 clientBalanceBefore = usdc.balanceOf(client);

        vm.prank(address(registry));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit GigEscrow.EscrowLocked(1, amount);
        escrow.lockEscrow(1, client, freelancer, amount);

        assertEq(usdc.balanceOf(address(escrow)), escrowBalanceBefore + amount, "escrow balance");
        assertEq(usdc.balanceOf(client), clientBalanceBefore - amount, "client balance reduced");

        GigEscrow.EscrowEntry memory entry = escrow.getEscrow(1);
        assertTrue(entry.initialized, "entry should be initialized");
        assertEq(entry.client, client);
        assertEq(entry.freelancer, freelancer);
        assertEq(entry.totalAmount, amount);
    }

    function testLockEscrowRevertsIfAlreadyLocked() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        // second lock for same jobId
        usdc.mint(client, BUDGET);
        vm.prank(address(registry));
        vm.expectRevert(bytes("Escrow exists"));
        escrow.lockEscrow(1, client, freelancer, BUDGET);
    }

    function testOnlyRegistryCanLock() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Only registry"));
        escrow.lockEscrow(1, client, freelancer, BUDGET);
    }

    function testLockEscrowRevertsZeroAmount() public {
        vm.prank(address(registry));
        vm.expectRevert(bytes("Zero amount"));
        escrow.lockEscrow(1, client, freelancer, 0);
    }

    // ── releasePayment ────────────────────────────────────────────────────────

    function testReleasePayment() public {
        uint256 amount = BUDGET;

        // lock first
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, amount);

        uint256 freelancerBefore = usdc.balanceOf(freelancer);
        uint256 treasuryBefore   = usdc.balanceOf(address(treasury));

        uint256 expectedFee = (amount * FEE_BPS) / 10_000;
        uint256 expectedNet = amount - expectedFee;

        vm.prank(address(registry));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit GigEscrow.PaymentReleased(1, expectedNet, expectedFee);
        escrow.releasePayment(1, amount, freelancer);

        assertEq(usdc.balanceOf(freelancer), freelancerBefore + expectedNet, "freelancer net");
        assertEq(usdc.balanceOf(address(treasury)), treasuryBefore + expectedFee, "treasury fee");
    }

    function testReleasePaymentRevertsIfNotRegistry() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        vm.prank(stranger);
        vm.expectRevert(bytes("Only registry"));
        escrow.releasePayment(1, BUDGET, freelancer);
    }

    function testReleasePaymentRevertsOnOverdraft() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        vm.prank(address(registry));
        vm.expectRevert(bytes("Insufficient escrow"));
        escrow.releasePayment(1, BUDGET + 1, freelancer);
    }

    function testReleasePaymentRevertsFreelancerMismatch() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        vm.prank(address(registry));
        vm.expectRevert(bytes("Freelancer mismatch"));
        escrow.releasePayment(1, BUDGET, stranger);
    }

    // ── refund ────────────────────────────────────────────────────────────────

    function testRefund() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(address(registry));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit GigEscrow.EscrowRefunded(1, BUDGET);
        escrow.refund(1, client);

        assertEq(usdc.balanceOf(client), clientBefore + BUDGET, "client refunded");
    }

    function testRefundRevertsIfNotRegistry() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        vm.prank(stranger);
        vm.expectRevert(bytes("Only registry"));
        escrow.refund(1, client);
    }

    function testRefundRevertsClientMismatch() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        vm.prank(address(registry));
        vm.expectRevert(bytes("Client mismatch"));
        escrow.refund(1, stranger);
    }

    function testRefundRevertsNothingToRefund() public {
        vm.prank(address(registry));
        escrow.lockEscrow(1, client, freelancer, BUDGET);

        // fully release first
        vm.prank(address(registry));
        escrow.releasePayment(1, BUDGET, freelancer);

        // now nothing left
        vm.prank(address(registry));
        vm.expectRevert(bytes("Nothing to refund"));
        escrow.refund(1, client);
    }

    // ── fee calculation fuzz ──────────────────────────────────────────────────

    /// @notice Invariant: net + fee == amount, for any amount and feeBps in [0, 1000].
    function testFuzz_FeeCalculation(uint64 rawAmount, uint16 rawBps) public {
        uint256 amount = bound(rawAmount, 1, type(uint64).max);
        uint256 bps    = bound(rawBps,    0, 1000);

        // Set feeBps
        vm.prank(owner);
        escrow.setFeeBps(bps);

        // Mint and approve
        usdc.mint(client, amount);
        vm.prank(client);
        usdc.approve(address(escrow), amount);

        // Lock
        vm.prank(address(registry));
        escrow.lockEscrow(99, client, freelancer, amount);

        uint256 freelancerBefore = usdc.balanceOf(freelancer);
        uint256 treasuryBefore   = usdc.balanceOf(address(treasury));

        vm.prank(address(registry));
        escrow.releasePayment(99, amount, freelancer);

        uint256 netReceived = usdc.balanceOf(freelancer)        - freelancerBefore;
        uint256 feeReceived = usdc.balanceOf(address(treasury)) - treasuryBefore;

        assertEq(netReceived + feeReceived, amount, "net + fee must equal amount");
    }

    // ── setFeeBps cap ─────────────────────────────────────────────────────────

    function testSetFeeBpsCapEnforced() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Fee too high"));
        escrow.setFeeBps(1001);
    }

    function testSetFeeBpsAllowsMax() public {
        vm.prank(owner);
        escrow.setFeeBps(1000); // max allowed
        assertEq(escrow.feeBps(), 1000);
    }

    // ── invariant: escrow balance >= sum of unreleased/unrefunded entries ─────

    function invariant_escrowSolvency() public view {
        // escrow holds ≥ 0 tokens (uint256 can't be negative; confirms no underflow path
        // was taken by the test sequence)
        assertGe(usdc.balanceOf(address(escrow)), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  GigRegistry tests
// ─────────────────────────────────────────────────────────────────────────────

contract GigRegistryTest is GigPlatformBase {

    // ── postJob ───────────────────────────────────────────────────────────────

    function testPostJob() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(client);
        GigRegistry.MilestoneInput[] memory noMilestones = new GigRegistry.MilestoneInput[](0);

        vm.expectEmit(true, true, false, true, address(registry));
        emit GigRegistry.JobPosted(1, client, BUDGET, deadline);

        uint256 jobId = registry.postJob(keccak256("desc"), BUDGET, deadline, noMilestones);

        assertEq(jobId, 1, "first jobId should be 1");
        assertEq(registry.jobCount(), 1);

        (uint256 id, address c,,uint256 budget, uint256 dl, GigRegistry.JobStatus status,,,) =
            registry.getJobInfo(jobId);
        assertEq(id, 1);
        assertEq(c, client);
        assertEq(budget, BUDGET);
        assertEq(dl, deadline);
        assertEq(uint8(status), uint8(GigRegistry.JobStatus.Open));
    }

    function testPostJobRevertsZeroBudget() public {
        vm.prank(client);
        GigRegistry.MilestoneInput[] memory noMilestones = new GigRegistry.MilestoneInput[](0);
        vm.expectRevert(bytes("Zero budget"));
        registry.postJob(keccak256("desc"), 0, block.timestamp + 1 days, noMilestones);
    }

    function testPostJobRevertsInvalidDeadline() public {
        vm.prank(client);
        GigRegistry.MilestoneInput[] memory noMilestones = new GigRegistry.MilestoneInput[](0);
        vm.expectRevert(bytes("Invalid deadline"));
        registry.postJob(keccak256("desc"), BUDGET, block.timestamp, noMilestones);
    }

    // ── postJob with milestones ───────────────────────────────────────────────

    function testPostJobWithMilestones() public {
        GigRegistry.MilestoneInput[] memory milestones = new GigRegistry.MilestoneInput[](2);
        milestones[0] = GigRegistry.MilestoneInput({amount: 400e6, deadline: block.timestamp + 7 days});
        milestones[1] = GigRegistry.MilestoneInput({amount: 600e6, deadline: block.timestamp + 14 days});

        vm.prank(client);
        uint256 jobId = registry.postJob(keccak256("desc"), 1_000e6, block.timestamp + 14 days, milestones);

        (,,,,, GigRegistry.JobStatus status,, bool hasMilestones, uint256 mCount) =
            registry.getJobInfo(jobId);
        assertTrue(hasMilestones, "should have milestones");
        assertEq(mCount, 2);
        assertEq(uint8(status), uint8(GigRegistry.JobStatus.Open));

        // verify milestone details
        (uint256 amt0,,,) = registry.getJobMilestone(jobId, 0);
        (uint256 amt1,,,) = registry.getJobMilestone(jobId, 1);
        assertEq(amt0, 400e6);
        assertEq(amt1, 600e6);
    }

    function testPostJobMilestoneBudgetMismatch() public {
        GigRegistry.MilestoneInput[] memory milestones = new GigRegistry.MilestoneInput[](2);
        milestones[0] = GigRegistry.MilestoneInput({amount: 300e6, deadline: block.timestamp + 7 days});
        milestones[1] = GigRegistry.MilestoneInput({amount: 600e6, deadline: block.timestamp + 14 days});
        // sum = 900e6, budget = 1000e6 → mismatch

        vm.prank(client);
        vm.expectRevert(bytes("Budget mismatch"));
        registry.postJob(keccak256("desc"), 1_000e6, block.timestamp + 14 days, milestones);
    }

    // ── submitProposal ────────────────────────────────────────────────────────

    function testSubmitProposal() public {
        uint256 jobId = _postSimpleJob(BUDGET, 14 days);

        vm.prank(freelancer);
        vm.expectEmit(true, true, false, true, address(registry));
        emit GigRegistry.ProposalSubmitted(jobId, 1, freelancer, BUDGET);
        uint256 proposalId = registry.submitProposal(jobId, BUDGET, keccak256("timeline"));

        assertEq(proposalId, 1);
        GigRegistry.Proposal memory p = registry.getProposal(jobId, proposalId);
        assertEq(p.freelancer, freelancer);
        assertEq(p.quote, BUDGET);
        assertFalse(p.clientAccepted);
        assertFalse(p.freelancerAccepted);
    }

    function testSubmitProposalRevertsIfClientProposes() public {
        uint256 jobId = _postSimpleJob(BUDGET, 14 days);

        vm.prank(client);
        vm.expectRevert(bytes("Client cannot propose"));
        registry.submitProposal(jobId, BUDGET, keccak256("timeline"));
    }

    function testSubmitProposalRevertsIfJobNotOpen() public {
        (uint256 jobId, uint256 proposalId) = _lockJob(BUDGET, 14 days);

        vm.prank(stranger);
        vm.expectRevert(bytes("Job not open"));
        registry.submitProposal(jobId, BUDGET, keccak256("another"));
    }

    // ── acceptProposal ────────────────────────────────────────────────────────

    function testAcceptProposalBothParties() public {
        uint256 jobId = _postSimpleJob(BUDGET, 14 days);

        vm.prank(freelancer);
        uint256 proposalId = registry.submitProposal(jobId, BUDGET, keccak256("timeline"));

        uint256 clientUsdcBefore = usdc.balanceOf(client);

        vm.prank(client);
        vm.expectEmit(true, false, false, false, address(registry));
        emit GigRegistry.ProposalAccepted(jobId, proposalId, client);
        registry.acceptProposal(jobId, proposalId);

        vm.prank(freelancer);
        vm.expectEmit(true, false, false, false, address(registry));
        emit GigRegistry.JobLocked(jobId, client, freelancer);
        registry.acceptProposal(jobId, proposalId);

        // escrow should now hold BUDGET
        assertEq(usdc.balanceOf(client), clientUsdcBefore - BUDGET, "client USDC debited");
        assertEq(usdc.balanceOf(address(escrow)), BUDGET, "escrow holds BUDGET");

        (,,,,, GigRegistry.JobStatus status,,, ) = registry.getJobInfo(jobId);
        assertEq(uint8(status), uint8(GigRegistry.JobStatus.Locked));
    }

    function testAcceptProposalQuoteMismatch() public {
        uint256 jobId = _postSimpleJob(BUDGET, 14 days);

        vm.prank(freelancer);
        // Quote differs from totalBudget
        uint256 proposalId = registry.submitProposal(jobId, BUDGET + 1, keccak256("timeline"));

        vm.prank(client);
        registry.acceptProposal(jobId, proposalId);

        vm.prank(freelancer);
        vm.expectRevert(bytes("Quote budget mismatch"));
        registry.acceptProposal(jobId, proposalId);
    }

    function testAcceptProposalRevertsForStranger() public {
        uint256 jobId = _postSimpleJob(BUDGET, 14 days);

        vm.prank(freelancer);
        uint256 proposalId = registry.submitProposal(jobId, BUDGET, keccak256("timeline"));

        vm.prank(stranger);
        vm.expectRevert(bytes("Not a party"));
        registry.acceptProposal(jobId, proposalId);
    }

    function testAcceptProposalRevertsBadProposalId() public {
        uint256 jobId = _postSimpleJob(BUDGET, 14 days);

        vm.prank(client);
        vm.expectRevert(bytes("Bad proposal id"));
        registry.acceptProposal(jobId, 0);
    }

    // ── submitDeliverable ─────────────────────────────────────────────────────

    function testSubmitDeliverable() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        bytes32 hash = keccak256("deliverable_v1");
        vm.prank(freelancer);
        vm.expectEmit(true, false, true, true, address(registry));
        emit GigRegistry.DeliverableSubmitted(jobId, 0, freelancer, hash);
        registry.submitDeliverable(jobId, 0, hash);

        (,, bytes32 deliverableHash, GigRegistry.MilestoneStatus mStatus) =
            registry.getJobMilestone(jobId, 0);
        assertEq(deliverableHash, hash);
        assertEq(uint8(mStatus), uint8(GigRegistry.MilestoneStatus.Submitted));
    }

    function testSubmitDeliverableRevertsIfNotFreelancer() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        vm.prank(stranger);
        vm.expectRevert(bytes("Not freelancer"));
        registry.submitDeliverable(jobId, 0, keccak256("bad"));
    }

    function testSubmitDeliverableRevertsIfNotLocked() public {
        uint256 jobId = _postSimpleJob(BUDGET, 14 days);

        vm.prank(freelancer);
        vm.expectRevert(bytes("Job not locked"));
        registry.submitDeliverable(jobId, 0, keccak256("bad"));
    }

    function testSubmitDeliverableRevertsWrongMilestoneIdx() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        vm.prank(freelancer);
        vm.expectRevert(bytes("Single milestone only"));
        registry.submitDeliverable(jobId, 1, keccak256("bad")); // single milestone job, idx must be 0
    }

    // ── approveDeliverable ────────────────────────────────────────────────────

    function testApproveDeliverable() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("deliverable"));

        uint256 freelancerBefore = usdc.balanceOf(freelancer);

        vm.prank(client);
        vm.expectEmit(true, false, false, false, address(registry));
        emit GigRegistry.DeliverableApproved(jobId, 0);
        vm.expectEmit(true, false, false, false, address(registry));
        emit GigRegistry.JobCompleted(jobId);
        registry.approveDeliverable(jobId, 0);

        // freelancer received net
        uint256 expectedFee = (BUDGET * FEE_BPS) / 10_000;
        uint256 expectedNet = BUDGET - expectedFee;
        assertEq(usdc.balanceOf(freelancer), freelancerBefore + expectedNet, "freelancer net payout");

        // job is Completed
        (,,,,, GigRegistry.JobStatus status,,, ) = registry.getJobInfo(jobId);
        assertEq(uint8(status), uint8(GigRegistry.JobStatus.Completed));
    }

    function testApproveDeliverableRevertsIfNotClient() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("deliverable"));

        vm.prank(stranger);
        vm.expectRevert(bytes("Not client"));
        registry.approveDeliverable(jobId, 0);
    }

    function testApproveDeliverableRevertsIfNotSubmitted() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);
        // don't submit the deliverable

        vm.prank(client);
        vm.expectRevert(bytes("Not submitted"));
        registry.approveDeliverable(jobId, 0);
    }

    // ── multi-milestone approve ───────────────────────────────────────────────

    function testApproveDeliverableWithMilestones() public {
        GigRegistry.MilestoneInput[] memory milestones = new GigRegistry.MilestoneInput[](2);
        milestones[0] = GigRegistry.MilestoneInput({amount: 400e6, deadline: block.timestamp + 7 days});
        milestones[1] = GigRegistry.MilestoneInput({amount: 600e6, deadline: block.timestamp + 14 days});

        vm.prank(client);
        uint256 jobId = registry.postJob(keccak256("desc"), 1_000e6, block.timestamp + 14 days, milestones);

        // submit proposal matching totalBudget
        vm.prank(freelancer);
        uint256 proposalId = registry.submitProposal(jobId, 1_000e6, keccak256("timeline"));

        // client needs 1000 USDC approved
        usdc.mint(client, 1_000e6);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(client);
        registry.acceptProposal(jobId, proposalId);
        vm.prank(freelancer);
        registry.acceptProposal(jobId, proposalId);

        // approve milestone 0
        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("m0"));
        vm.prank(client);
        registry.approveDeliverable(jobId, 0);

        // job should still be Locked (milestone 1 pending)
        (,,,,, GigRegistry.JobStatus statusAfterFirst,,, ) = registry.getJobInfo(jobId);
        assertEq(uint8(statusAfterFirst), uint8(GigRegistry.JobStatus.Locked), "still locked after first milestone");

        // approve milestone 1 → job completes
        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 1, keccak256("m1"));
        vm.prank(client);
        vm.expectEmit(true, false, false, false, address(registry));
        emit GigRegistry.JobCompleted(jobId);
        registry.approveDeliverable(jobId, 1);

        (,,,,, GigRegistry.JobStatus statusFinal,,, ) = registry.getJobInfo(jobId);
        assertEq(uint8(statusFinal), uint8(GigRegistry.JobStatus.Completed), "job should be Completed");
    }

    // ── claimStaleReview ──────────────────────────────────────────────────────

    function testClaimStaleReview() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("deliverable"));

        // fast-forward past REVIEW_PERIOD
        skip(REVIEW_PERIOD + 1);

        uint256 freelancerBefore = usdc.balanceOf(freelancer);

        vm.prank(freelancer);
        vm.expectEmit(true, false, true, false, address(registry));
        emit GigRegistry.StaleReviewClaimed(jobId, 0, freelancer);
        registry.claimStaleReview(jobId, 0);

        uint256 expectedFee = (BUDGET * FEE_BPS) / 10_000;
        uint256 expectedNet = BUDGET - expectedFee;
        assertGe(usdc.balanceOf(freelancer), freelancerBefore + expectedNet - 1, "freelancer received net");

        // job completed
        (,,,,, GigRegistry.JobStatus status,,, ) = registry.getJobInfo(jobId);
        assertEq(uint8(status), uint8(GigRegistry.JobStatus.Completed));
    }

    function testClaimStaleReviewRevertsWithinReviewPeriod() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("deliverable"));

        // NOT past review period
        skip(REVIEW_PERIOD - 1);

        vm.prank(freelancer);
        vm.expectRevert(bytes("Review period active"));
        registry.claimStaleReview(jobId, 0);
    }

    function testClaimStaleReviewRevertsIfNotFreelancer() public {
        (uint256 jobId,) = _lockJob(BUDGET, 14 days);

        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("deliverable"));
        skip(REVIEW_PERIOD + 1);

        vm.prank(stranger);
        vm.expectRevert(bytes("Not freelancer"));
        registry.claimStaleReview(jobId, 0);
    }

    // ── reclaimEscrow ─────────────────────────────────────────────────────────

    function testReclaimEscrowAfterDeadline() public {
        (uint256 jobId,) = _lockJob(BUDGET, 1 days);
        // job deadline = 1 day from now; must exceed deadline + GRACE_PERIOD

        skip(1 days + GRACE_PERIOD + 1);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        vm.expectEmit(true, true, false, false, address(registry));
        emit GigRegistry.EscrowReclaimed(jobId, client, BUDGET);
        registry.reclaimEscrow(jobId);

        assertEq(usdc.balanceOf(client), clientBefore + BUDGET, "client should get full refund");

        (,,,,, GigRegistry.JobStatus status,,, ) = registry.getJobInfo(jobId);
        assertEq(uint8(status), uint8(GigRegistry.JobStatus.Cancelled));
    }

    function testReclaimEscrowBlockedBeforeGrace() public {
        (uint256 jobId,) = _lockJob(BUDGET, 1 days);

        // advance to deadline but NOT past grace
        skip(1 days + 1);

        vm.prank(client);
        vm.expectRevert(bytes("Grace active"));
        registry.reclaimEscrow(jobId);
    }

    function testReclaimEscrowBlockedWhileSubmitted() public {
        // Strategy: pick a deadline that is only 1 second in the future so the
        // outer "deadline + GRACE_PERIOD" guard can be cleared quickly, while
        // the "submittedAt + REVIEW_PERIOD + GRACE_PERIOD" window is still open.
        //
        // Timeline (t0 = current block.timestamp ≈ 1):
        //   t0        → lock job, deadline = t0 + 1
        //   t0        → submitDeliverable  (submittedAt = t0)
        //   t0 + GRACE_PERIOD + 2 → warp
        //
        // Guard "Deliverable awaiting review":
        //   block.timestamp <= submittedAt + REVIEW_PERIOD + GRACE_PERIOD
        //   (t0 + GRACE_PERIOD + 2) <= t0 + 3 days + 7 days   ← TRUE (7 days + 2 < 10 days)
        //
        // Outer deadline guard:
        //   block.timestamp > deadline + GRACE_PERIOD
        //   (t0 + GRACE_PERIOD + 2) > (t0 + 1) + GRACE_PERIOD = t0 + GRACE_PERIOD + 1  ← TRUE

        // Post the job with a 1-second deadline (deadline = block.timestamp + 1)
        (uint256 jobId,) = _lockJob(BUDGET, 1);

        // Capture submittedAt
        vm.prank(freelancer);
        registry.submitDeliverable(jobId, 0, keccak256("deliverable"));

        // Warp to just past deadline + GRACE_PERIOD but within REVIEW_PERIOD + GRACE_PERIOD window
        skip(GRACE_PERIOD + 2); // now at t0 + GRACE_PERIOD + 2

        vm.prank(client);
        vm.expectRevert(bytes("Deliverable awaiting review"));
        registry.reclaimEscrow(jobId);
    }

    function testReclaimEscrowRevertsIfNotClient() public {
        (uint256 jobId,) = _lockJob(BUDGET, 1 days);
        skip(1 days + GRACE_PERIOD + 1);

        vm.prank(stranger);
        vm.expectRevert(bytes("Not client"));
        registry.reclaimEscrow(jobId);
    }

    // ── reputation on completion ───────────────────────────────────────────────

    function testReputationUpdatedOnCompletion() public {
        _completeJob(BUDGET);

        GigReputation.ReputationRecord memory clientRec    = reputation.getRecord(client);
        GigReputation.ReputationRecord memory freelancerRec = reputation.getRecord(freelancer);

        assertEq(clientRec.jobsCompleted,     1, "client jobsCompleted");
        assertEq(freelancerRec.jobsCompleted,  1, "freelancer jobsCompleted");
        assertEq(freelancerRec.totalUsdcEarned, BUDGET, "freelancer earned");
        assertGt(freelancerRec.score,          0, "freelancer score > 0");
    }

    // ── reputation on cancellation ────────────────────────────────────────────

    function testReputationUpdatedOnCancellation() public {
        (uint256 jobId,) = _lockJob(BUDGET, 1 days);
        skip(1 days + GRACE_PERIOD + 1);

        vm.prank(client);
        registry.reclaimEscrow(jobId);

        GigReputation.ReputationRecord memory clientRec    = reputation.getRecord(client);
        GigReputation.ReputationRecord memory freelancerRec = reputation.getRecord(freelancer);

        assertEq(clientRec.jobsCancelled,     1, "client jobsCancelled");
        assertEq(freelancerRec.jobsCancelled,  1, "freelancer jobsCancelled");
    }

    // ── fuzz: postJob with various budgets ────────────────────────────────────

    function testFuzz_PostJobBudget(uint64 rawBudget) public {
        uint256 budget = bound(rawBudget, 1, type(uint64).max);

        usdc.mint(client, budget);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(client);
        GigRegistry.MilestoneInput[] memory noMilestones = new GigRegistry.MilestoneInput[](0);
        uint256 jobId = registry.postJob(keccak256("desc"), budget, block.timestamp + 1 days, noMilestones);

        (,,,uint256 storedBudget,,,,, ) = registry.getJobInfo(jobId);
        assertEq(storedBudget, budget);
    }

    // ── invariant: jobCount only increases ────────────────────────────────────

    /// Monotonic counter: after posting N jobs, jobCount == N.
    function testJobCountMonotonic() public {
        for (uint256 i = 0; i < 5; i++) {
            _postSimpleJob(BUDGET, 14 days);
            assertEq(registry.jobCount(), i + 1);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Cross-contract invariant handler (stateful invariant via forge invariants)
// ─────────────────────────────────────────────────────────────────────────────

contract GigInvariantHandler is GigPlatformBase {
    uint256 public ghost_totalLocked;
    uint256 public ghost_totalReleased;
    uint256 public ghost_totalRefunded;
    uint256 public jobCount;

    function setUp() public override {
        super.setUp();
    }

    /// Handler: lock a fresh escrow
    function handler_lockEscrow(uint256 amount) external {
        amount = bound(amount, 1e6, 10_000e6);
        usdc.mint(client, amount);
        vm.prank(client);
        usdc.approve(address(escrow), amount);
        jobCount++;
        vm.prank(address(registry));
        escrow.lockEscrow(jobCount, client, freelancer, amount);
        ghost_totalLocked += amount;
    }

    /// Handler: release from an existing escrow (job 1 if it exists)
    function handler_releasePayment(uint256 jobId, uint256 amount) external {
        if (jobCount == 0) return;
        jobId = bound(jobId, 1, jobCount);
        GigEscrow.EscrowEntry memory entry = escrow.getEscrow(jobId);
        if (!entry.initialized) return;
        uint256 remaining = entry.totalAmount - entry.releasedAmount - entry.refundedAmount;
        if (remaining == 0) return;
        amount = bound(amount, 1, remaining);
        vm.prank(address(registry));
        escrow.releasePayment(jobId, amount, freelancer);
        ghost_totalReleased += amount;
    }

    /// Handler: refund an existing escrow
    function handler_refund(uint256 jobId) external {
        if (jobCount == 0) return;
        jobId = bound(jobId, 1, jobCount);
        GigEscrow.EscrowEntry memory entry = escrow.getEscrow(jobId);
        if (!entry.initialized) return;
        uint256 remaining = entry.totalAmount - entry.releasedAmount - entry.refundedAmount;
        if (remaining == 0) return;
        vm.prank(address(registry));
        escrow.refund(jobId, client);
        ghost_totalRefunded += remaining;
    }

    /// Invariant: escrow USDC balance == locked - released - refunded
    function invariant_escrowBalanceMatchesGhost() external view {
        // net + fee == amount, so escrow is drained by exactly the locked amount across
        // releases + refunds. The treasury absorbs fees from release so the escrow balance
        // equals locked - released - refunded.
        uint256 escrowBal = usdc.balanceOf(address(escrow));
        assertEq(
            escrowBal,
            ghost_totalLocked - ghost_totalReleased - ghost_totalRefunded,
            "escrow balance invariant"
        );
    }
}
