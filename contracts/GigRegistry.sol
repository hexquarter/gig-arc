// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

interface IGigEscrow {
    function lockEscrow(uint256 jobId, address client, address freelancer, uint256 amount) external;
    function releasePayment(uint256 jobId, uint256 amount, address freelancer) external;
    function refund(uint256 jobId, address client) external;
}

interface IGigReputation {
    function recordCompletion(address client, address freelancer, uint256 usdcAmount) external;
    function recordCancellation(address client, address freelancer) external;
}

contract GigRegistry is Initializable, UUPSUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant MAX_MILESTONES = 20;
    uint256 public constant GRACE_PERIOD = 7 days;
    uint256 public constant REVIEW_PERIOD = 3 days;

    enum JobStatus {
        Open,
        Locked,
        Completed,
        Cancelled
    }

    enum MilestoneStatus {
        Pending,
        Submitted,
        Approved,
        Refunded
    }

    struct MilestoneInput {
        uint256 amount;
        uint256 deadline;
    }

    struct Milestone {
        uint256 amount;
        uint256 deadline;
        bytes32 deliverableHash;
        MilestoneStatus status;
    }

    struct Job {
        uint256 id;
        address client;
        bytes32 descHash;
        uint256 totalBudget;
        uint256 deadline;
        JobStatus status;
        uint256 acceptedProposalId;
        bool hasMilestones;
        uint256 milestoneCount;
        mapping(uint256 => Milestone) milestones;
    }

    struct Proposal {
        uint256 id;
        address freelancer;
        uint256 quote;
        bytes32 timelineHash;
        bool clientAccepted;
        bool freelancerAccepted;
    }

    /// @custom:storage-location erc7201:gigregistry.v1
    struct GigRegistryStorage {
        mapping(uint256 => Job) jobs;
        mapping(uint256 => mapping(uint256 => Proposal)) proposals;
        mapping(uint256 => uint256) proposalCount;
        mapping(uint256 => mapping(uint256 => uint256)) milestoneSubmittedAt;
        uint256 jobCount;
        address gigEscrow;
        address gigReputation;
    }

    // Pre-computed: keccak256(abi.encode(uint256(keccak256("gigregistry.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GIGREGISTRY_STORAGE_SLOT =
        0xb4c82dd702a5602df11c5c6a33d72449b613961d9f75309d27e9192dd8bf4000;

    event JobPosted(uint256 indexed jobId, address indexed client, uint256 budget, uint256 deadline);
    event ProposalSubmitted(uint256 indexed jobId, uint256 proposalId, address indexed freelancer, uint256 quote);
    event ProposalAccepted(uint256 indexed jobId, uint256 proposalId, address indexed by);
    event JobLocked(uint256 indexed jobId, address indexed client, address indexed freelancer);
    event DeliverableSubmitted(uint256 indexed jobId, uint256 milestoneIdx, address indexed freelancer, bytes32 contentHash);
    event DeliverableApproved(uint256 indexed jobId, uint256 milestoneIdx);
    event PaymentReleased(uint256 indexed jobId, uint256 milestoneIdx, uint256 amount);
    event StaleReviewClaimed(uint256 indexed jobId, uint256 milestoneIdx, address indexed freelancer);
    event EscrowReclaimed(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobCompleted(uint256 indexed jobId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _gigEscrow, address _gigReputation, address _owner) external initializer {
        if (_gigEscrow == address(0)) revert("Zero escrow");
        if (_gigReputation == address(0)) revert("Zero reputation");
        if (_owner == address(0)) revert("Zero owner");

        __Pausable_init();
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        GigRegistryStorage storage $ = _getStorage();
        $.gigEscrow = _gigEscrow;
        $.gigReputation = _gigReputation;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function postJob(
        bytes32 descHash,
        uint256 totalBudget,
        uint256 deadline,
        MilestoneInput[] calldata milestoneInputs
    ) external whenNotPaused returns (uint256 jobId) {
        if (deadline <= block.timestamp) revert("Invalid deadline");
        if (totalBudget == 0) revert("Zero budget");

        GigRegistryStorage storage $ = _getStorage();
        jobId = ++$.jobCount;

        Job storage job = $.jobs[jobId];
        job.id = jobId;
        job.client = msg.sender;
        job.descHash = descHash;
        job.totalBudget = totalBudget;
        job.status = JobStatus.Open;

        if (milestoneInputs.length > 0) {
            if (milestoneInputs.length > MAX_MILESTONES) revert("Too many milestones");

            uint256 sum = 0;
            uint256 lastDeadline = 0;

            for (uint256 i = 0; i < milestoneInputs.length; i++) {
                MilestoneInput calldata inputMilestone = milestoneInputs[i];
                if (inputMilestone.deadline <= block.timestamp) revert("Milestone deadline");

                sum += inputMilestone.amount;
                lastDeadline = inputMilestone.deadline;

                job.milestones[i] = Milestone({
                    amount: inputMilestone.amount,
                    deadline: inputMilestone.deadline,
                    deliverableHash: bytes32(0),
                    status: MilestoneStatus.Pending
                });
            }

            if (sum != totalBudget) revert("Budget mismatch");

            job.hasMilestones = true;
            job.milestoneCount = milestoneInputs.length;
            job.deadline = lastDeadline;
        } else {
            job.hasMilestones = false;
            job.milestoneCount = 1;
            job.deadline = deadline;
            job.milestones[0] = Milestone({
                amount: totalBudget,
                deadline: deadline,
                deliverableHash: bytes32(0),
                status: MilestoneStatus.Pending
            });
        }

        emit JobPosted(jobId, msg.sender, totalBudget, job.deadline);
    }

    function submitProposal(uint256 jobId, uint256 quote, bytes32 timelineHash) external whenNotPaused returns (uint256 proposalId) {
        if (quote == 0) revert("Zero quote");

        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];

        if (!_jobExists(job)) revert("Job missing");
        if (job.status != JobStatus.Open) revert("Job not open");
        if (msg.sender == job.client) revert("Client cannot propose");

        proposalId = ++$.proposalCount[jobId];
        $.proposals[jobId][proposalId] = Proposal({
            id: proposalId,
            freelancer: msg.sender,
            quote: quote,
            timelineHash: timelineHash,
            clientAccepted: false,
            freelancerAccepted: false
        });

        emit ProposalSubmitted(jobId, proposalId, msg.sender, quote);
    }

    function acceptProposal(uint256 jobId, uint256 proposalId) external whenNotPaused nonReentrant {
        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];

        if (!_jobExists(job)) revert("Job missing");
        if (job.status != JobStatus.Open) revert("Job not open");
        if (proposalId == 0 || proposalId > $.proposalCount[jobId]) revert("Bad proposal id");

        Proposal storage proposal = $.proposals[jobId][proposalId];

        if (msg.sender == job.client) {
            proposal.clientAccepted = true;
        } else if (msg.sender == proposal.freelancer) {
            proposal.freelancerAccepted = true;
        } else {
            revert("Not a party");
        }

        emit ProposalAccepted(jobId, proposalId, msg.sender);

        if (proposal.clientAccepted && proposal.freelancerAccepted) {
            if (proposal.quote != job.totalBudget) revert("Quote budget mismatch");

            job.status = JobStatus.Locked;
            job.acceptedProposalId = proposalId;

            IGigEscrow($.gigEscrow).lockEscrow(jobId, job.client, proposal.freelancer, job.totalBudget);
            emit JobLocked(jobId, job.client, proposal.freelancer);
        }
    }

    function submitDeliverable(uint256 jobId, uint256 milestoneIdx, bytes32 contentHash) external whenNotPaused {
        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];

        if (!_jobExists(job)) revert("Job missing");
        if (job.status != JobStatus.Locked) revert("Job not locked");

        Proposal storage proposal = $.proposals[jobId][job.acceptedProposalId];
        if (msg.sender != proposal.freelancer) revert("Not freelancer");

        if (job.hasMilestones) {
            if (milestoneIdx >= job.milestoneCount) revert("Bad milestone");
        } else {
            if (milestoneIdx != 0) revert("Single milestone only");
        }

        Milestone storage milestone = job.milestones[milestoneIdx];
        if (milestone.status != MilestoneStatus.Pending) revert("Not pending");

        milestone.deliverableHash = contentHash;
        milestone.status = MilestoneStatus.Submitted;
        $.milestoneSubmittedAt[jobId][milestoneIdx] = block.timestamp;

        emit DeliverableSubmitted(jobId, milestoneIdx, msg.sender, contentHash);
    }

    function approveDeliverable(uint256 jobId, uint256 milestoneIdx) external whenNotPaused nonReentrant {
        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];

        if (!_jobExists(job)) revert("Job missing");
        if (job.status != JobStatus.Locked) revert("Job not locked");
        if (msg.sender != job.client) revert("Not client");

        if (job.hasMilestones) {
            if (milestoneIdx >= job.milestoneCount) revert("Bad milestone");
        } else {
            if (milestoneIdx != 0) revert("Single milestone only");
        }

        Milestone storage milestone = job.milestones[milestoneIdx];
        if (milestone.status != MilestoneStatus.Submitted) revert("Not submitted");

        Proposal storage proposal = $.proposals[jobId][job.acceptedProposalId];

        milestone.status = MilestoneStatus.Approved;

        IGigEscrow($.gigEscrow).releasePayment(jobId, milestone.amount, proposal.freelancer);

        emit DeliverableApproved(jobId, milestoneIdx);
        emit PaymentReleased(jobId, milestoneIdx, milestone.amount);

        if (_allMilestonesApproved(job)) {
            job.status = JobStatus.Completed;
            IGigReputation($.gigReputation).recordCompletion(job.client, proposal.freelancer, job.totalBudget);
            emit JobCompleted(jobId);
        }
    }

    function claimStaleReview(uint256 jobId, uint256 milestoneIdx) external whenNotPaused nonReentrant {
        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];

        if (!_jobExists(job)) revert("Job missing");
        if (job.status != JobStatus.Locked) revert("Job not locked");

        Proposal storage proposal = $.proposals[jobId][job.acceptedProposalId];
        if (msg.sender != proposal.freelancer) revert("Not freelancer");

        if (job.hasMilestones) {
            if (milestoneIdx >= job.milestoneCount) revert("Bad milestone");
        } else {
            if (milestoneIdx != 0) revert("Single milestone only");
        }

        Milestone storage milestone = job.milestones[milestoneIdx];
        if (milestone.status != MilestoneStatus.Submitted) revert("Not submitted");

        if (block.timestamp <= $.milestoneSubmittedAt[jobId][milestoneIdx] + REVIEW_PERIOD) revert("Review period active");

        milestone.status = MilestoneStatus.Approved;

        IGigEscrow($.gigEscrow).releasePayment(jobId, milestone.amount, proposal.freelancer);

        emit DeliverableApproved(jobId, milestoneIdx);
        emit PaymentReleased(jobId, milestoneIdx, milestone.amount);
        emit StaleReviewClaimed(jobId, milestoneIdx, proposal.freelancer);

        if (_allMilestonesApproved(job)) {
            job.status = JobStatus.Completed;
            IGigReputation($.gigReputation).recordCompletion(job.client, proposal.freelancer, job.totalBudget);
            emit JobCompleted(jobId);
        }
    }

    function reclaimEscrow(uint256 jobId) external whenNotPaused nonReentrant {
        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];

        if (!_jobExists(job)) revert("Job missing");
        if (job.status != JobStatus.Locked) revert("Job not locked");
        if (msg.sender != job.client) revert("Not client");

        for (uint256 i = 0; i < job.milestoneCount; i++) {
            Milestone storage milestone = job.milestones[i];
            if (milestone.status == MilestoneStatus.Submitted) {
                if (block.timestamp <= $.milestoneSubmittedAt[jobId][i] + REVIEW_PERIOD + GRACE_PERIOD) {
                    revert("Deliverable awaiting review");
                }
            }
        }

        Proposal storage proposal = $.proposals[jobId][job.acceptedProposalId];

        uint256 effectiveDeadline = _effectiveReclaimDeadline(job);
        if (block.timestamp <= effectiveDeadline + GRACE_PERIOD) revert("Grace active");

        job.status = JobStatus.Cancelled;

        for (uint256 i = 0; i < job.milestoneCount; i++) {
            Milestone storage milestone = job.milestones[i];
            if (milestone.status == MilestoneStatus.Pending || milestone.status == MilestoneStatus.Submitted) {
                milestone.status = MilestoneStatus.Refunded;
            }
        }

        IGigEscrow($.gigEscrow).refund(jobId, job.client);
        IGigReputation($.gigReputation).recordCancellation(job.client, proposal.freelancer);

        emit EscrowReclaimed(jobId, job.client, job.totalBudget);
    }

    function getJobInfo(uint256 jobId)
        external
        view
        returns (
            uint256 id,
            address client,
            bytes32 descHash,
            uint256 totalBudget,
            uint256 deadline,
            JobStatus status,
            uint256 acceptedProposalId,
            bool hasMilestones,
            uint256 milestoneCount
        )
    {
        Job storage job = _getStorage().jobs[jobId];
        if (!_jobExists(job)) revert("Job missing");

        return (
            job.id,
            job.client,
            job.descHash,
            job.totalBudget,
            job.deadline,
            job.status,
            job.acceptedProposalId,
            job.hasMilestones,
            job.milestoneCount
        );
    }

    function getJobMilestone(uint256 jobId, uint256 idx)
        external
        view
        returns (uint256 amount, uint256 deadline, bytes32 deliverableHash, MilestoneStatus status)
    {
        Job storage job = _getStorage().jobs[jobId];
        if (!_jobExists(job)) revert("Job missing");
        if (idx >= job.milestoneCount) revert("Bad milestone");

        Milestone storage milestone = job.milestones[idx];
        return (milestone.amount, milestone.deadline, milestone.deliverableHash, milestone.status);
    }

    function getProposal(uint256 jobId, uint256 proposalId) external view returns (Proposal memory) {
        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];
        if (!_jobExists(job)) revert("Job missing");
        if (proposalId == 0 || proposalId > $.proposalCount[jobId]) revert("Bad proposal id");

        return $.proposals[jobId][proposalId];
    }

    function getAcceptedFreelancer(uint256 jobId) external view returns (address) {
        GigRegistryStorage storage $ = _getStorage();
        Job storage job = $.jobs[jobId];
        if (!_jobExists(job)) revert("Job missing");
        if (job.acceptedProposalId == 0) return address(0);

        return $.proposals[jobId][job.acceptedProposalId].freelancer;
    }

    function jobCount() external view returns (uint256) {
        return _getStorage().jobCount;
    }

    function gigEscrow() external view returns (address) {
        return _getStorage().gigEscrow;
    }

    function gigReputation() external view returns (address) {
        return _getStorage().gigReputation;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Disabled");
    }

    /// @dev v1: upgrade authority is owner (multisig). v2 should add a TimelockController for delayed upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _allMilestonesApproved(Job storage job) private view returns (bool) {
        for (uint256 i = 0; i < job.milestoneCount; i++) {
            if (job.milestones[i].status != MilestoneStatus.Approved) {
                return false;
            }
        }
        return true;
    }

    function _effectiveReclaimDeadline(Job storage job) private view returns (uint256) {
        if (!job.hasMilestones) {
            return job.deadline;
        }

        bool found = false;
        uint256 earliest = 0;

        for (uint256 i = 0; i < job.milestoneCount; i++) {
            Milestone storage milestone = job.milestones[i];
            if (milestone.status == MilestoneStatus.Pending) {
                if (!found || milestone.deadline < earliest) {
                    earliest = milestone.deadline;
                    found = true;
                }
            }
        }

        if (!found) {
            return job.deadline;
        }

        return earliest;
    }

    function _jobExists(Job storage job) private view returns (bool) {
        return job.id != 0;
    }

    function _getStorage() private pure returns (GigRegistryStorage storage $) {
        assembly {
            $.slot := GIGREGISTRY_STORAGE_SLOT
        }
    }
}
