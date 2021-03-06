pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import './../Utils/SafeMath.sol';

contract GovFunding {
    using SafeMath for uint256;
    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    /// @notice The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH = keccak256("Ballot(uint256 proposalId,bool support)");
    /// @notice The name of this contract
    string public constant name = "Governance Funding";
    /// @notice The number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    uint256 public quorumVotes;
    /// @notice The number of votes required in order for a voter to be able to vote
    uint256 public voteRequirement;
    /// @notice The duration of voting on a proposal, in blocks
    uint256 public votingPeriod;
    /// @notice The address of the Voice Gov Coordinator
    address public voiceGov;
    /// @notice The address of the Mute token
    IMuteContract public mute;
    /// @notice The total number of proposals
    uint256 public proposalCount;

    struct Proposal {
        /// @notice Unique id for looking up a proposal
        uint256 id;
        /// @notice Creator of the proposal
        address proposer;
        /// @notice The target to execute the proposal data
        address target;
        /// @notice The ordered list of calldata to be passed to each call
        bytes data;
        /// @notice The block at which voting begins: holders must delegate their votes prior to this block
        uint256 startBlock;
        /// @notice The block at which voting ends: votes must be cast prior to this block
        uint256 endBlock;
        /// @notice Current number of votes in favor of this proposal
        uint256 forVotes;
        /// @notice Current number of votes in opposition to this proposal
        uint256 againstVotes;
        /// @notice Flag marking whether the proposal has been executed
        bool executed;
        /// @notice Receipts of ballots for the entire set of voters
        mapping (address => Receipt) receipts;
    }
    /// @notice Ballot receipt record for a voter
    struct Receipt {
        /// @notice Whether or not a vote has been cast
        bool hasVoted;
        /// @notice Whether or not the voter supports the proposal
        bool support;
        /// @notice The number of votes the voter had, which were cast
        uint96 votes;
    }
    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Expired,
        Executed
    }

    /// @notice The official record of all proposals ever proposed
    mapping (uint256 => Proposal) public proposals;
    /// @notice The latest proposal for each proposer
    mapping (address => uint) public latestProposalIds;

    /// @notice An event emitted when a new proposal is created
    event ProposalCreated(uint256 id, address proposer, bytes data, uint256 startBlock, uint256 endBlock, string description);
    /// @notice An event emitted when a vote has been cast on a proposal
    event VoteCast(address voter, uint256 proposalId, bool support, uint256 votes);
    /// @notice An event emitted when a proposal has been executed in the Timelock
    event ProposalExecuted(uint256 id);

    constructor(address _voiceGov, address _mute, uint256 _votingPeriod) public {
        quorumVotes = 4000000e18; // 4,000,000 mute (20% of circ)
        voteRequirement = 40000e18; // 40,000 mute
        votingPeriod = _votingPeriod;//34560; // ~6 days in blocks (assuming 15s blocks)

        voiceGov = _voiceGov;
        mute = IMuteContract(_mute);
    }

    // should only be called by itself, only proposals created by MUTE holders
    function changeQuorumVotes(uint256 _quorumVotes) public {
        require(msg.sender == address(this));
        quorumVotes = _quorumVotes;
    }

    // should only be called by itself, only proposals created by MUTE holders
    function changeVotingPeriod(uint256 _votingPeriod) public {
        require(msg.sender == address(this));
        votingPeriod = _votingPeriod;
    }

    // should only be called by itself, only proposals created by MUTE holders
    function changeVoteRequirement(uint256 _voteRequirement) public {
        require(msg.sender == address(this));
        voteRequirement = _voteRequirement;
    }

    function propose(address target, bytes memory data, string memory description) public returns (uint) {

        if(target != address(this)){
          // not an internal target, only allow the govcoord contract
          require(msg.sender == voiceGov, "GovFunding::propose: only voice gov can propose");
        } else {
          // allow mute holders to change votingPeriod / quorumvotes / voteRequirement
          require(mute.getPriorVotes(msg.sender, block.number.sub(1)) > voteRequirement, "GovFunding::propose: proposer votes below proposal threshold");
        }

        uint256 latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
          ProposalState proposersLatestProposalState = state(latestProposalId);
          require(proposersLatestProposalState != ProposalState.Active, "GovFunding::propose: one live proposal per proposer, found an already active proposal");
          require(proposersLatestProposalState != ProposalState.Pending, "GovFunding::propose: one live proposal per proposer, found an already pending proposal");
        }

        uint256 startBlock = block.number.add(1);
        uint256 endBlock = startBlock.add(votingPeriod);

        proposalCount++;
        Proposal memory newProposal = Proposal({
            id: proposalCount,
            proposer: msg.sender,
            target: target,
            data: data,
            startBlock: startBlock,
            endBlock: endBlock,
            forVotes: 0,
            againstVotes: 0,
            executed: false
        });

        proposals[newProposal.id] = newProposal;
        latestProposalIds[newProposal.proposer] = newProposal.id;

        emit ProposalCreated(newProposal.id, msg.sender, data, startBlock, endBlock, description);
        return newProposal.id;
    }

    function execute(uint256 proposalId) public payable {
        require(state(proposalId) == ProposalState.Succeeded, "GovFunding::execute: proposal can only be succeeded to execute");
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        (bool result, ) = address(proposal.target).call(proposal.data);
        if (!result) {
            revert("GovFunding::execute: transaction Failed");
        }
        emit ProposalExecuted(proposalId);
    }

    function getAction(uint256 proposalId) public view returns (bytes memory data) {
        Proposal storage p = proposals[proposalId];
        return p.data;
    }

    function getReceipt(uint256 proposalId, address voter) public view returns (Receipt memory) {
        return proposals[proposalId].receipts[voter];
    }

    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalCount >= proposalId && proposalId > 0, "GovFunding::state: invalid proposal id");
        Proposal storage proposal = proposals[proposalId];
        if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes.add(proposal.againstVotes) < quorumVotes) {
            return ProposalState.Defeated;
        } else if (proposal.executed == false) {
            return ProposalState.Succeeded;
        } else if (proposal.executed == true) {
            return ProposalState.Executed;
        } else if (block.timestamp >= proposal.endBlock) {
            return ProposalState.Expired;
        }
    }

    function castVote(uint256 proposalId, bool support) public {
        return _castVote(msg.sender, proposalId, support);
    }

    function castVoteBySig(uint256 proposalId, bool support, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), getChainId(), address(this)));
        bytes32 structHash = keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "GovFunding::castVoteBySig: invalid signature");
        return _castVote(signatory, proposalId, support);
    }

    function _castVote(address voter, uint256 proposalId, bool support) internal {
        require(state(proposalId) == ProposalState.Active, "GovFunding::_castVote: voting is closed");

        require(mute.getPriorVotes(voter, block.number.sub(1)) > voteRequirement, "GovFunding::propose: proposer votes below voter threshold");

        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        require(receipt.hasVoted == false, "GovFunding::_castVote: voter already voted");
        uint96 votes = mute.getPriorVotes(voter, proposal.startBlock);

        if (support) {
            proposal.forVotes = proposal.forVotes.add(votes);
        } else {
            proposal.againstVotes = proposal.againstVotes.add(votes);
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        emit VoteCast(voter, proposalId, support, votes);
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}

interface IMuteContract {
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint96);
}
