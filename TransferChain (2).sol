// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TransferChain
 * @notice Automates financial settlement of professional football player transfers.
 *         Handles installment schedules, solidarity contributions, sell-on clauses,
 *         agent commissions, and protocol fees in a single self-executing contract.
 *
 * @dev Deployment requires multi-party consensus before the contract becomes active.
 *      Once activated, installments are released by any caller once block.timestamp >= dueDate.
 *      Payments are pushed to all recipients in one transaction (push pattern).
 *      Failed individual payments are tracked in failedPayments[] for admin rescue
 *      rather than reverting or corrupting the installment status.
 *
 * Design decisions (per Group 14 questionnaire):
 *   Q1  – A1: Single admin wallet (FIFA) can register the contract
 *   Q2  – A1: Anyone can trigger release once block.timestamp >= dueDate
 *   Q3  – A2: Up to 20 recipients per contract
 *   Q4  – B1: One contract per transfer deal
 *   Q5  – B3: Up to 5 installments, each with independent date and amount
 *   Q6  – B2: Each installment has its own bespoke split (basis points)
 *             + FIFA agent commission hard caps enforced on-chain
 *   Q7  – C1: All three streams: solidarity + sell-on + agent commission
 *   Q8  – C1: Single-level sell-on clause only
 *   Q9  – C1 + multi-party consensus gate before activation
 *   Q10 – D2: Push pattern — funds sent to all recipients on release
 *   Q11 – D2: Admin can redirect stuck funds to a new address
 *   Q12 – D1: Native test ETH on Sepolia (stablecoin noted for full MVP)
 *   Q13 – E3: 2-of-3 multi-sig attestation (FIFA admin + national assoc + club)
 *             falls back to E1 (admin only) if complexity too high
 *   Q14 – E1: Refundable stake deferred to full MVP
 *   Q15 – F2: Hardhat script demo (no frontend required)
 *   Q16 – F1: 5 wallets: Admin, Buyer, Seller, Academy, Agent
 */
contract TransferChain is AccessControl, ReentrancyGuard {

    // ─────────────────────────────────────────────
    //  ROLES
    // ─────────────────────────────────────────────

    /// @dev FIFA / league administrator — registers contracts, can redirect stuck funds
    bytes32 public constant FIFA_ADMIN_ROLE = keccak256("FIFA_ADMIN_ROLE");
    /// @dev National football association (e.g. FA, DFB) — one of the consensus signers
    bytes32 public constant NAT_ASSOC_ROLE  = keccak256("NAT_ASSOC_ROLE");
    /// @dev Buying club — one of the consensus signers and the fund depositor
    bytes32 public constant BUYER_CLUB_ROLE = keccak256("BUYER_CLUB_ROLE");

    // ─────────────────────────────────────────────
    //  CONSTANTS
    // ─────────────────────────────────────────────

    uint16 public constant BASIS_POINTS          = 10_000;

    /// @dev FIFA agent commission hard cap (basis points): 6% per agent entry
    uint16 public constant AGENT_CAP_BPS         = 600;

    /// @dev Solidarity contribution fixed rate under FIFA RSTP Art. 21 (5%)
    uint16 public constant SOLIDARITY_RATE_BPS   = 500;

    /// @dev Protocol fee range: 0.1% – 0.2%
    uint16 public constant PROTOCOL_FEE_MIN_BPS  = 10;
    uint16 public constant PROTOCOL_FEE_MAX_BPS  = 20;

    /// @dev Maximum recipients per contract
    uint8  public constant MAX_RECIPIENTS        = 20;

    /// @dev Maximum installments per contract
    uint8  public constant MAX_INSTALLMENTS      = 5;

    // ─────────────────────────────────────────────
    //  ENUMS
    // ─────────────────────────────────────────────

    enum RecipientType {
        SELLING_CLUB,    // 0 – receives residual after all deductions
        SOLIDARITY_CLUB, // 1 – training academy / former club (FIFA RSTP Art.21)
        SELLON_CLUB,     // 2 – club holding a sell-on clause
        AGENT,           // 3 – licensed intermediary
        PROTOCOL_FEE     // 4 – TransferChain protocol wallet
    }

    enum InstallmentStatus {
        PENDING,  // 0 – not yet due
        RELEASED, // 1 – released and funds distributed (even if some pushes failed)
        FAILED    // 2 – reserved; not set automatically (see failedPayments instead)
    }

    enum ContractStatus {
        AWAITING_CONSENSUS, // 0 – pending multi-party signatures before activation
        ACTIVE,             // 1 – funded and running
        COMPLETED,          // 2 – all installments released
        CANCELLED           // 3 – cancelled before activation
    }

    // ─────────────────────────────────────────────
    //  STRUCTS
    // ─────────────────────────────────────────────

    struct Recipient {
        address payable wallet;
        RecipientType   recipientType;
        string          name;   // human-readable label for demo
        bool            active;
    }

    /**
     * @dev Per-installment distribution entry.
     *      recipientIndex references the recipients[] array.
     *      shareBps is this recipient's share of THIS installment in basis points.
     *      All shareBps values for a given installment must sum to exactly 10,000.
     */
    struct DistributionEntry {
        uint8  recipientIndex;
        uint16 shareBps;
    }

    struct Installment {
        uint256           amount;       // ETH amount for this tranche (in wei)
        uint256           dueDate;      // Unix timestamp after which release is allowed
        InstallmentStatus status;
        DistributionEntry[] distribution; // bespoke per-installment split
    }

    // ─────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────

    /// @notice Human-readable deal identifier (e.g. "Mbappé — PSG → Real Madrid")
    string  public dealName;

    /// @notice Protocol fee wallet address
    address payable public protocolWallet;

    /// @notice Protocol fee in basis points (must be between 10 and 20)
    uint16  public protocolFeeBps;

    ContractStatus public status;

    /// @notice Registered recipients for this transfer deal
    Recipient[]   public recipients;

    /// @notice Installment schedule
    Installment[] public installments;

    /// @notice Index of the next installment to be released (0-based)
    uint8 public nextInstallment;

    /// @notice Total ETH deposited by the buyer club
    uint256 public totalDeposited;

    /**
     * @notice Tracks ETH amounts that failed to push to recipients during release.
     * @dev    Maps installmentIndex => recipientWallet => weiAmount.
     *         Admin uses rescueFunds() to recover these amounts.
     *         The parent installment remains in RELEASED state; only the individual
     *         push failed. This prevents a single uncooperative wallet from
     *         blocking the entire installment settlement.
     */
    mapping(uint8 => mapping(address => uint256)) public failedPayments;

    // ─────────────────────────────────────────────
    //  MULTI-PARTY CONSENSUS
    //
    //  Required signers before activation:
    //    1. FIFA admin      (always required)
    //    2. National assoc  (always required)
    //    3. Buyer club      (always required)
    //
    //  All three must call approveActivation() before the contract
    //  can receive funds. This mirrors FIFA TMS validation logic.
    // ─────────────────────────────────────────────

    mapping(address => bool) public hasApproved;
    uint8  public approvalCount;
    uint8  public constant REQUIRED_APPROVALS = 3;

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

    event ContractRegistered(string dealName, address indexed admin);
    event ActivationApproved(address indexed approver, uint8 totalApprovals);
    event ContractActivated(string dealName);
    event FundsDeposited(address indexed buyer, uint256 amount);
    event InstallmentReleased(
        uint8   indexed installmentIndex,
        uint256 amount,
        uint256 timestamp
    );
    event PaymentSent(
        uint8   indexed installmentIndex,
        address indexed recipient,
        RecipientType   recipientType,
        string          recipientName,
        uint256         amount
    );
    event PaymentFailed(
        uint8   indexed installmentIndex,
        address indexed recipient,
        uint256         amount
    );
    event FundsRedirected(
        uint8   indexed recipientIndex,
        address indexed oldWallet,
        address indexed newWallet,
        address         authorizedBy
    );
    event ContractCancelled(address indexed cancelledBy);

    // ─────────────────────────────────────────────
    //  ERRORS
    // ─────────────────────────────────────────────

    error NotAwaitingConsensus();
    error AlreadyApproved();
    error NotActive();
    error AlreadyActive();
    error TooManyRecipients();
    error TooManyInstallments();
    error InvalidBasisPoints();
    error AgentCommissionExceedsCap();
    error ProtocolFeeOutOfRange();
    error InstallmentNotDue();
    error InstallmentAlreadyReleased();
    error NoInstallmentsRemaining();
    error InsufficientFunds();
    error ZeroAddress();
    error InvalidInstallmentAmount();
    error InvalidRecipientIndex();
    error DueDateNotInFuture();   // NEW: rejects past or zero due dates
    error NothingToRescue();      // NEW: rescueFunds called with amount == 0

    // ─────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────

    /**
     * @param _dealName        Human-readable transfer deal name
     * @param _protocolWallet  Address that receives protocol fees
     * @param _protocolFeeBps  Protocol fee in basis points (10–20)
     * @param _fifaAdmin       Address granted FIFA_ADMIN_ROLE
     * @param _natAssoc        Address granted NAT_ASSOC_ROLE
     * @param _buyerClub       Address granted BUYER_CLUB_ROLE
     */
    constructor(
        string  memory _dealName,
        address payable _protocolWallet,
        uint16  _protocolFeeBps,
        address _fifaAdmin,
        address _natAssoc,
        address _buyerClub
    ) {
        if (_protocolWallet == address(0)) revert ZeroAddress();
        if (_fifaAdmin      == address(0)) revert ZeroAddress();
        if (_natAssoc       == address(0)) revert ZeroAddress();
        if (_buyerClub      == address(0)) revert ZeroAddress();
        if (_protocolFeeBps < PROTOCOL_FEE_MIN_BPS || _protocolFeeBps > PROTOCOL_FEE_MAX_BPS)
            revert ProtocolFeeOutOfRange();

        dealName       = _dealName;
        protocolWallet = _protocolWallet;
        protocolFeeBps = _protocolFeeBps;
        status         = ContractStatus.AWAITING_CONSENSUS;

        _grantRole(DEFAULT_ADMIN_ROLE, _fifaAdmin);
        _grantRole(FIFA_ADMIN_ROLE,    _fifaAdmin);
        _grantRole(NAT_ASSOC_ROLE,     _natAssoc);
        _grantRole(BUYER_CLUB_ROLE,    _buyerClub);

        emit ContractRegistered(_dealName, _fifaAdmin);
    }

    // ─────────────────────────────────────────────
    //  MODIFIERS
    // ─────────────────────────────────────────────

    modifier onlyActive() {
        if (status != ContractStatus.ACTIVE) revert NotActive();
        _;
    }

    modifier onlyAwaitingConsensus() {
        if (status != ContractStatus.AWAITING_CONSENSUS) revert NotAwaitingConsensus();
        _;
    }

    // ═════════════════════════════════════════════
    //  STEP 1 — MULTI-PARTY CONSENSUS
    // ═════════════════════════════════════════════

    /**
     * @notice Called by each required party (FIFA admin, national assoc, buyer club)
     *         to approve activation of this transfer contract.
     *         All three must approve before the contract becomes ACTIVE.
     */
    function approveActivation()
        external
        onlyAwaitingConsensus
    {
        bool isFifa  = hasRole(FIFA_ADMIN_ROLE,  msg.sender);
        bool isAssoc = hasRole(NAT_ASSOC_ROLE,   msg.sender);
        bool isBuyer = hasRole(BUYER_CLUB_ROLE,  msg.sender);

        require(isFifa || isAssoc || isBuyer, "Not an authorized approver");
        if (hasApproved[msg.sender]) revert AlreadyApproved();

        hasApproved[msg.sender] = true;
        approvalCount++;

        emit ActivationApproved(msg.sender, approvalCount);

        if (approvalCount >= REQUIRED_APPROVALS) {
            status = ContractStatus.ACTIVE;
            emit ContractActivated(dealName);
        }
    }

    // ═════════════════════════════════════════════
    //  STEP 2 — REGISTRATION (FIFA admin only)
    // ═════════════════════════════════════════════

    /**
     * @notice Register all recipients for this deal.
     *         Must be called after activation, before any deposit.
     *         Can only be called once (recipients array must be empty).
     */
    function registerRecipients(
        address payable[] calldata wallets,
        RecipientType[]   calldata types,
        string[]          calldata names
    )
        external
        onlyRole(FIFA_ADMIN_ROLE)
        onlyActive
    {
        require(recipients.length == 0, "Recipients already registered");
        require(
            wallets.length == types.length && wallets.length == names.length,
            "Array length mismatch"
        );
        if (wallets.length > MAX_RECIPIENTS) revert TooManyRecipients();

        for (uint8 i = 0; i < wallets.length; i++) {
            if (wallets[i] == address(0)) revert ZeroAddress();
            recipients.push(Recipient({
                wallet:        wallets[i],
                recipientType: types[i],
                name:          names[i],
                active:        true
            }));
        }
    }

    /**
     * @notice Register the installment schedule with bespoke per-installment splits.
     *         Must be called after registerRecipients().
     *
     * @param amounts        ETH amounts per installment (wei)
     * @param dueDates       Unix timestamps — must be strictly increasing AND in the future
     * @param recipientIdxs  For each installment: array of recipient indices
     * @param sharesBps      For each installment: array of basis-point shares
     *                       (must sum to 10,000 per installment)
     */
    function registerInstallments(
        uint256[]   calldata amounts,
        uint256[]   calldata dueDates,
        uint8[][]   calldata recipientIdxs,
        uint16[][]  calldata sharesBps
    )
        external
        onlyRole(FIFA_ADMIN_ROLE)
        onlyActive
    {
        require(installments.length == 0, "Installments already registered");
        require(recipients.length   > 0,  "Register recipients first");
        require(
            amounts.length == dueDates.length &&
            amounts.length == recipientIdxs.length &&
            amounts.length == sharesBps.length,
            "Array length mismatch"
        );
        if (amounts.length > MAX_INSTALLMENTS) revert TooManyInstallments();

        uint256 prevDate = block.timestamp; // FIX: all due dates must be strictly after now
        for (uint8 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0)          revert InvalidInstallmentAmount();
            // FIX: reject past or present timestamps
            if (dueDates[i] <= prevDate)  revert DueDateNotInFuture();
            prevDate = dueDates[i];

            _validateDistribution(recipientIdxs[i], sharesBps[i]);

            installments.push();
            Installment storage inst = installments[installments.length - 1];
            inst.amount  = amounts[i];
            inst.dueDate = dueDates[i];
            inst.status  = InstallmentStatus.PENDING;

            for (uint8 j = 0; j < recipientIdxs[i].length; j++) {
                inst.distribution.push(DistributionEntry({
                    recipientIndex: recipientIdxs[i][j],
                    shareBps:       sharesBps[i][j]
                }));
            }
        }
    }

    // ═════════════════════════════════════════════
    //  STEP 3 — DEPOSIT (buyer club)
    // ═════════════════════════════════════════════

    /**
     * @notice Buyer club deposits the full transfer fee into escrow.
     *         Must equal the sum of all installment amounts exactly.
     */
    function deposit()
        external
        payable
        onlyRole(BUYER_CLUB_ROLE)
        onlyActive
        nonReentrant
    {
        require(installments.length > 0, "No installments registered");
        require(totalDeposited      == 0, "Already deposited");

        uint256 required = _totalInstallmentAmount();
        if (msg.value != required) revert InsufficientFunds();

        totalDeposited = msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }

    // ═════════════════════════════════════════════
    //  STEP 4 — RELEASE (anyone, after due date)
    // ═════════════════════════════════════════════

    /**
     * @notice Release the next pending installment.
     *         Can be called by any address once block.timestamp >= dueDate.
     *         Distributes funds to all recipients via push pattern.
     *
     * @dev Two-pass dust-safe distribution:
     *        Pass 1 – calculate all per-recipient payments in memory and sum them.
     *        Pass 2 – add any integer-division remainder (dust) to the first payment,
     *                 then push all payments.
     *      This guarantees the full installment amount is always distributed,
     *      eliminating permanent wei-level residuals from basis-point truncation.
     *
     *      If an individual push fails (e.g. recipient is a contract with no receive()),
     *      the failed amount is recorded in failedPayments[installmentIndex][wallet].
     *      The installment status remains RELEASED so subsequent installments are
     *      not blocked. Admin uses rescueFunds() to recover failed amounts.
     */
    function releaseNextInstallment()
        external
        onlyActive
        nonReentrant
    {
        if (nextInstallment >= installments.length) revert NoInstallmentsRemaining();

        Installment storage inst = installments[nextInstallment];
        if (inst.status != InstallmentStatus.PENDING) revert InstallmentAlreadyReleased();
        if (block.timestamp < inst.dueDate)           revert InstallmentNotDue();
        if (address(this).balance < inst.amount)      revert InsufficientFunds();

        // Mark released and advance counter BEFORE external calls (re-entrancy safety)
        inst.status = InstallmentStatus.RELEASED;
        uint8 idx   = nextInstallment;
        nextInstallment++;

        emit InstallmentReleased(idx, inst.amount, block.timestamp);

        uint256 len = inst.distribution.length;

        // ── Pass 1: calculate payments and collect dust ───────────────────
        uint256[] memory payments  = new uint256[](len);
        uint256          totalCalc = 0;

        for (uint8 i = 0; i < len; i++) {
            payments[i] = (inst.amount * inst.distribution[i].shareBps) / BASIS_POINTS;
            totalCalc  += payments[i];
        }

        // FIX: add integer-division remainder to the first entry
        uint256 dust = inst.amount - totalCalc;
        if (dust > 0 && len > 0) {
            payments[0] += dust;
        }

        // ── Pass 2: push payments ─────────────────────────────────────────
        for (uint8 i = 0; i < len; i++) {
            if (payments[i] == 0) continue;

            DistributionEntry memory entry = inst.distribution[i];
            Recipient storage rec = recipients[entry.recipientIndex];

            (bool sent, ) = rec.wallet.call{value: payments[i]}("");
            if (sent) {
                emit PaymentSent(idx, rec.wallet, rec.recipientType, rec.name, payments[i]);
            } else {
                // FIX: track failed amount instead of corrupting installment status.
                // The installment remains RELEASED; admin rescues via rescueFunds().
                failedPayments[idx][rec.wallet] += payments[i];
                emit PaymentFailed(idx, rec.wallet, payments[i]);
            }
        }

        if (nextInstallment == installments.length) {
            status = ContractStatus.COMPLETED;
        }
    }

    // ═════════════════════════════════════════════
    //  ADMIN — REDIRECT STUCK FUNDS
    // ═════════════════════════════════════════════

    /**
     * @notice FIFA admin redirects a recipient's wallet to a new address.
     *         Use this before calling rescueFunds() when the original address
     *         is a broken contract or compromised wallet.
     *
     * @param recipientIndex  Index in the recipients[] array
     * @param newWallet       New valid wallet address for this recipient
     */
    function redirectRecipientWallet(
        uint8           recipientIndex,
        address payable newWallet
    )
        external
        onlyRole(FIFA_ADMIN_ROLE)
    {
        if (recipientIndex >= recipients.length) revert InvalidRecipientIndex();
        if (newWallet      == address(0))        revert ZeroAddress();

        address oldWallet = recipients[recipientIndex].wallet;
        recipients[recipientIndex].wallet = newWallet;

        emit FundsRedirected(recipientIndex, oldWallet, newWallet, msg.sender);
    }

    /**
     * @notice Manually push ETH remaining in the contract to a specific recipient.
     *         Used to recover from failed push payments recorded in failedPayments[].
     *
     * @param installmentIndex  Installment the failed payment came from (for event accuracy)
     * @param recipientIndex    Index in the recipients[] array
     * @param amount            Amount in wei to send
     */
    function rescueFunds(
        uint8   installmentIndex,
        uint8   recipientIndex,
        uint256 amount
    )
        external
        onlyRole(FIFA_ADMIN_ROLE)
        nonReentrant
    {
        if (recipientIndex >= recipients.length) revert InvalidRecipientIndex();
        // FIX: revert on zero amount instead of silently succeeding
        if (amount == 0)                         revert NothingToRescue();
        if (address(this).balance < amount)      revert InsufficientFunds();

        Recipient storage rec = recipients[recipientIndex];

        (bool sent, ) = rec.wallet.call{value: amount}("");
        require(sent, "Rescue transfer failed");

        // Decrement tracked failure if applicable
        uint256 tracked = failedPayments[installmentIndex][rec.wallet];
        if (tracked >= amount) {
            failedPayments[installmentIndex][rec.wallet] -= amount;
        }

        // FIX: emit with the correct installment index (was previously `nextInstallment`)
        emit PaymentSent(installmentIndex, rec.wallet, rec.recipientType, rec.name, amount);
    }

    // ═════════════════════════════════════════════
    //  ADMIN — CANCEL (before activation only)
    // ═════════════════════════════════════════════

    /**
     * @notice Cancel this contract before it is activated.
     *         Once ACTIVE, funds are in escrow and installments will release.
     */
    function cancelContract()
        external
        onlyRole(FIFA_ADMIN_ROLE)
        onlyAwaitingConsensus
    {
        status = ContractStatus.CANCELLED;
        emit ContractCancelled(msg.sender);
    }

    // ═════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═════════════════════════════════════════════

    /// @notice Returns the number of registered recipients
    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    /// @notice Returns the number of registered installments
    function installmentCount() external view returns (uint256) {
        return installments.length;
    }

    /// @notice Returns summary info for a specific installment
    function getInstallment(uint8 index)
        external
        view
        returns (
            uint256           amount,
            uint256           dueDate,
            InstallmentStatus instStatus,
            uint256           distributionCount
        )
    {
        require(index < installments.length, "Index out of range");
        Installment storage inst = installments[index];
        return (inst.amount, inst.dueDate, inst.status, inst.distribution.length);
    }

    /// @notice Returns a specific distribution entry for a given installment
    function getDistributionEntry(uint8 installmentIndex, uint8 entryIndex)
        external
        view
        returns (uint8 recipientIndex, uint16 shareBps)
    {
        require(installmentIndex < installments.length, "Installment index out of range");
        Installment storage inst = installments[installmentIndex];
        require(entryIndex < inst.distribution.length,  "Entry index out of range");
        DistributionEntry memory entry = inst.distribution[entryIndex];
        return (entry.recipientIndex, entry.shareBps);
    }

    /// @notice Returns summary info for a specific recipient
    function getRecipient(uint8 index)
        external
        view
        returns (
            address       wallet,
            RecipientType recipientType,
            string memory name,
            bool          active
        )
    {
        require(index < recipients.length, "Index out of range");
        Recipient storage rec = recipients[index];
        return (rec.wallet, rec.recipientType, rec.name, rec.active);
    }

    /// @notice Returns current contract balance
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns whether the next installment is currently releasable
    function isNextInstallmentReleasable() external view returns (bool) {
        if (status != ContractStatus.ACTIVE)           return false;
        if (nextInstallment >= installments.length)    return false;
        Installment storage inst = installments[nextInstallment];
        if (inst.status != InstallmentStatus.PENDING)  return false;
        return block.timestamp >= inst.dueDate;
    }

    /// @notice Returns seconds remaining until next installment is due (0 if already due)
    function secondsUntilNextInstallment() external view returns (uint256) {
        if (nextInstallment >= installments.length) return 0;
        Installment storage inst = installments[nextInstallment];
        if (block.timestamp >= inst.dueDate) return 0;
        return inst.dueDate - block.timestamp;
    }

    /**
     * @notice Returns the failed payment amount owed to a wallet for a given installment.
     * @dev    Use this to check whether rescueFunds() is needed after a failed push.
     */
    function getFailedPayment(uint8 installmentIndex, address wallet)
        external
        view
        returns (uint256)
    {
        return failedPayments[installmentIndex][wallet];
    }

    /**
     * @notice Returns true if any push payment failed for the given installment.
     * @dev    Loops through the distribution array to check failedPayments entries.
     */
    function hasPartialFailure(uint8 installmentIndex)
        external
        view
        returns (bool)
    {
        if (installmentIndex >= installments.length) return false;
        Installment storage inst = installments[installmentIndex];
        for (uint8 i = 0; i < inst.distribution.length; i++) {
            address wallet = recipients[inst.distribution[i].recipientIndex].wallet;
            if (failedPayments[installmentIndex][wallet] > 0) return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═════════════════════════════════════════════

    /**
     * @dev Validates a distribution array for one installment:
     *      1. All recipient indices are within bounds
     *      2. Agent entries do not exceed AGENT_CAP_BPS (6%)
     *      3. All basis points sum to exactly 10,000
     */
    function _validateDistribution(
        uint8[]  calldata idxs,
        uint16[] calldata bps
    ) internal view {
        require(idxs.length == bps.length, "Distribution array mismatch");
        uint256 total = 0;
        for (uint8 i = 0; i < idxs.length; i++) {
            if (idxs[i] >= recipients.length) revert InvalidRecipientIndex();
            if (recipients[idxs[i]].recipientType == RecipientType.AGENT) {
                if (bps[i] > AGENT_CAP_BPS) revert AgentCommissionExceedsCap();
            }
            total += bps[i];
        }
        if (total != BASIS_POINTS) revert InvalidBasisPoints();
    }

    /// @dev Returns the sum of all installment amounts
    function _totalInstallmentAmount() internal view returns (uint256 total) {
        for (uint8 i = 0; i < installments.length; i++) {
            total += installments[i].amount;
        }
    }

    /**
     * @dev Reject plain ETH transfers. All funding must go through deposit().
     *      The original empty receive() allowed anyone to send arbitrary ETH,
     *      inflating contractBalance() and confusing the accounting.
     */
    receive() external payable {
        revert("Use deposit() to fund this contract");
    }
}
