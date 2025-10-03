;; ballot-contract
;; Smart contract to securely record and tally votes

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u200))
(define-constant ERR_NOT_FOUND (err u201))
(define-constant ERR_UNAUTHORIZED (err u202))
(define-constant ERR_VOTING_CLOSED (err u203))
(define-constant ERR_ALREADY_VOTED (err u204))
(define-constant ERR_INVALID_CANDIDATE (err u205))
(define-constant ERR_ELECTION_NOT_STARTED (err u206))
(define-constant ERR_INVALID_BALLOT (err u207))
(define-constant ERR_RESULTS_FINALIZED (err u208))
(define-constant ERR_ELECTION_ACTIVE (err u209))

;; Vote statuses
(define-constant VOTE_STATUS_CAST "cast")
(define-constant VOTE_STATUS_VERIFIED "verified")
(define-constant VOTE_STATUS_COUNTED "counted")
(define-constant VOTE_STATUS_INVALID "invalid")

;; Election statuses
(define-constant ELECTION_STATUS_SETUP "setup")
(define-constant ELECTION_STATUS_ACTIVE "active")
(define-constant ELECTION_STATUS_CLOSED "closed")
(define-constant ELECTION_STATUS_FINALIZED "finalized")

;; Data Variables
(define-data-var current-election-id uint u0)
(define-data-var vote-counter uint u0)
(define-data-var voting-active bool false)
(define-data-var election-status (string-ascii 20) ELECTION_STATUS_SETUP)
(define-data-var results-finalized bool false)

;; Data Maps
(define-map elections
    { election-id: uint }
    {
        title: (string-ascii 128),
        description: (string-ascii 512),
        start-time: uint,
        end-time: uint,
        status: (string-ascii 20),
        total-votes: uint,
        total-candidates: uint,
        creator: principal,
        results-hash: (optional (buff 32))
    }
)

(define-map candidates
    { election-id: uint, candidate-id: uint }
    {
        name: (string-ascii 128),
        description: (string-ascii 256),
        party: (optional (string-ascii 64)),
        vote-count: uint,
        active: bool
    }
)

(define-map votes
    { vote-id: uint }
    {
        election-id: uint,
        voter-address: principal,
        candidate-id: uint,
        vote-hash: (buff 32),
        timestamp: uint,
        status: (string-ascii 20),
        verification-hash: (optional (buff 32))
    }
)

(define-map voter-ballots
    { voter-address: principal, election-id: uint }
    {
        vote-id: uint,
        submitted: bool,
        timestamp: uint
    }
)

(define-map election-results
    { election-id: uint }
    {
        winner-candidate-id: uint,
        winning-votes: uint,
        total-valid-votes: uint,
        total-invalid-votes: uint,
        turnout-percentage: uint,
        finalized-timestamp: uint,
        certified: bool
    }
)

(define-map election-monitors
    { monitor: principal, election-id: uint }
    { authorized: bool, role: (string-ascii 32) }
)

(define-map vote-verification
    { vote-id: uint }
    {
        verified: bool,
        verification-timestamp: uint,
        verifier: principal,
        notes: (optional (string-ascii 256))
    }
)

(define-map candidate-counter-by-election
    { election-id: uint }
    { count: uint }
)

;; Public Functions

;; Create a new election (owner only)
(define-public (create-election
    (title (string-ascii 128))
    (description (string-ascii 512))
    (duration uint))
    (let (
        (election-id (+ (var-get current-election-id) u1))
        (current-time stacks-block-height)
        (end-time (+ current-time duration))
    )
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        ;; Validate duration (at least 1 day, max 30 days in blocks)
        (asserts! (and (>= duration u1440) (<= duration u43200)) ERR_INVALID_BALLOT)
        
        ;; Create election record
        (map-set elections
            { election-id: election-id }
            {
                title: title,
                description: description,
                start-time: current-time,
                end-time: end-time,
                status: ELECTION_STATUS_SETUP,
                total-votes: u0,
                total-candidates: u0,
                creator: tx-sender,
                results-hash: none
            }
        )
        
        ;; Initialize candidate counter
        (map-set candidate-counter-by-election
            { election-id: election-id }
            { count: u0 }
        )
        
        ;; Update current election
        (var-set current-election-id election-id)
        (var-set election-status ELECTION_STATUS_SETUP)
        
        (ok election-id)
    )
)

;; Add candidate to election (owner only)
(define-public (add-candidate
    (election-id uint)
    (name (string-ascii 128))
    (description (string-ascii 256))
    (party (optional (string-ascii 64))))
    (let (
        (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_NOT_FOUND))
        (candidate-count (get count (unwrap-panic (map-get? candidate-counter-by-election { election-id: election-id }))))
        (candidate-id (+ candidate-count u1))
    )
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        ;; Check if election is in setup phase
        (asserts! (is-eq (get status election-data) ELECTION_STATUS_SETUP) ERR_ELECTION_ACTIVE)
        ;; Check candidate limit (max 20 candidates)
        (asserts! (< candidate-count u20) ERR_INVALID_CANDIDATE)
        
        ;; Add candidate
        (map-set candidates
            { election-id: election-id, candidate-id: candidate-id }
            {
                name: name,
                description: description,
                party: party,
                vote-count: u0,
                active: true
            }
        )
        
        ;; Update candidate counter
        (map-set candidate-counter-by-election
            { election-id: election-id }
            { count: candidate-id }
        )
        
        ;; Update election total candidates
        (map-set elections
            { election-id: election-id }
            (merge election-data { total-candidates: candidate-id })
        )
        
        (ok candidate-id)
    )
)

;; Start election voting (owner only)
(define-public (start-election (election-id uint))
    (let (
        (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_NOT_FOUND))
    )
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        ;; Check if election is in setup phase
        (asserts! (is-eq (get status election-data) ELECTION_STATUS_SETUP) ERR_ELECTION_ACTIVE)
        ;; Check if at least 2 candidates exist
        (asserts! (>= (get total-candidates election-data) u2) ERR_INVALID_CANDIDATE)
        
        ;; Start election
        (map-set elections
            { election-id: election-id }
            (merge election-data { status: ELECTION_STATUS_ACTIVE })
        )
        
        ;; Update global state
        (var-set current-election-id election-id)
        (var-set voting-active true)
        (var-set election-status ELECTION_STATUS_ACTIVE)
        
        (ok true)
    )
)

;; Cast vote
(define-public (cast-vote
    (election-id uint)
    (candidate-id uint))
    (let (
        (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_NOT_FOUND))
        (candidate-data (unwrap! (map-get? candidates { election-id: election-id, candidate-id: candidate-id }) ERR_INVALID_CANDIDATE))
        (vote-id (+ (var-get vote-counter) u1))
        (current-time stacks-block-height)
        (vote-hash (keccak256 (concat 
            (concat (unwrap-panic (to-consensus-buff? election-id)) (unwrap-panic (to-consensus-buff? candidate-id)))
            (concat (unwrap-panic (to-consensus-buff? tx-sender)) (unwrap-panic (to-consensus-buff? current-time))))))
    )
        ;; Check if election is active
        (asserts! (is-eq (get status election-data) ELECTION_STATUS_ACTIVE) ERR_VOTING_CLOSED)
        ;; Check if voting period is still open
        (asserts! (<= current-time (get end-time election-data)) ERR_VOTING_CLOSED)
        ;; Check if candidate is active
        (asserts! (get active candidate-data) ERR_INVALID_CANDIDATE)
        ;; Check if voter hasn't already voted
        (asserts! (is-none (map-get? voter-ballots { voter-address: tx-sender, election-id: election-id })) ERR_ALREADY_VOTED)
        
        ;; Record vote
        (map-set votes
            { vote-id: vote-id }
            {
                election-id: election-id,
                voter-address: tx-sender,
                candidate-id: candidate-id,
                vote-hash: vote-hash,
                timestamp: current-time,
                status: VOTE_STATUS_CAST,
                verification-hash: none
            }
        )
        
        ;; Record voter ballot
        (map-set voter-ballots
            { voter-address: tx-sender, election-id: election-id }
            {
                vote-id: vote-id,
                submitted: true,
                timestamp: current-time
            }
        )
        
        ;; Update candidate vote count
        (map-set candidates
            { election-id: election-id, candidate-id: candidate-id }
            (merge candidate-data { vote-count: (+ (get vote-count candidate-data) u1) })
        )
        
        ;; Update election vote count
        (map-set elections
            { election-id: election-id }
            (merge election-data { total-votes: (+ (get total-votes election-data) u1) })
        )
        
        ;; Update vote counter
        (var-set vote-counter vote-id)
        
        ;; Try to mark voter as voted in voter registry (if available)
        ;; This would normally be a cross-contract call
        
        (ok vote-id)
    )
)

;; Close election (owner only)
(define-public (close-election (election-id uint))
    (let (
        (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_NOT_FOUND))
        (current-time stacks-block-height)
    )
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        ;; Check if election is active
        (asserts! (is-eq (get status election-data) ELECTION_STATUS_ACTIVE) ERR_VOTING_CLOSED)
        
        ;; Close election
        (map-set elections
            { election-id: election-id }
            (merge election-data { status: ELECTION_STATUS_CLOSED })
        )
        
        ;; Update global state
        (var-set voting-active false)
        (var-set election-status ELECTION_STATUS_CLOSED)
        
        (ok true)
    )
)

;; Finalize election results (owner only)
(define-public (finalize-election (election-id uint))
    (let (
        (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_NOT_FOUND))
        (current-time stacks-block-height)
        (total-candidates (get total-candidates election-data))
    )
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        ;; Check if election is closed
        (asserts! (is-eq (get status election-data) ELECTION_STATUS_CLOSED) ERR_ELECTION_ACTIVE)
        ;; Check if not already finalized
        (asserts! (not (var-get results-finalized)) ERR_RESULTS_FINALIZED)
        
        ;; Calculate winner (simple implementation - highest vote count)
        (let (
            (winner-info (fold find-winner-candidate (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 
                                                           u11 u12 u13 u14 u15 u16 u17 u18 u19 u20)
                              { election-id: election-id, max-votes: u0, winner-id: u0, total-candidates: total-candidates }))
        )
            ;; Record final results
            (map-set election-results
                { election-id: election-id }
                {
                    winner-candidate-id: (get winner-id winner-info),
                    winning-votes: (get max-votes winner-info),
                    total-valid-votes: (get total-votes election-data),
                    total-invalid-votes: u0, ;; Simplified - no invalid vote tracking in this implementation
                    turnout-percentage: u100, ;; Simplified calculation
                    finalized-timestamp: current-time,
                    certified: true
                }
            )
            
            ;; Update election status
            (map-set elections
                { election-id: election-id }
                (merge election-data { status: ELECTION_STATUS_FINALIZED })
            )
            
            ;; Update global state
            (var-set election-status ELECTION_STATUS_FINALIZED)
            (var-set results-finalized true)
            
            (ok (get winner-id winner-info))
        )
    )
)

;; Verify vote (monitor only)
(define-public (verify-vote (vote-id uint))
    (let (
        (vote-data (unwrap! (map-get? votes { vote-id: vote-id }) ERR_NOT_FOUND))
        (current-time stacks-block-height)
    )
        ;; Check if sender is authorized monitor
        (asserts! (default-to false (get authorized 
            (map-get? election-monitors { monitor: tx-sender, election-id: (get election-id vote-data) }))) ERR_UNAUTHORIZED)
        
        ;; Update vote status
        (map-set votes
            { vote-id: vote-id }
            (merge vote-data { status: VOTE_STATUS_VERIFIED })
        )
        
        ;; Record verification
        (map-set vote-verification
            { vote-id: vote-id }
            {
                verified: true,
                verification-timestamp: current-time,
                verifier: tx-sender,
                notes: none
            }
        )
        
        (ok true)
    )
)

;; Authorize election monitor (owner only)
(define-public (authorize-monitor 
    (monitor principal) 
    (election-id uint)
    (role (string-ascii 32)))
    (begin
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        
        ;; Authorize monitor
        (map-set election-monitors
            { monitor: monitor, election-id: election-id }
            { authorized: true, role: role }
        )
        
        (ok true)
    )
)

;; Private helper function for finding winner
(define-private (find-winner-candidate (candidate-id uint) (acc { election-id: uint, max-votes: uint, winner-id: uint, total-candidates: uint }))
    (if (<= candidate-id (get total-candidates acc))
        (match (map-get? candidates { election-id: (get election-id acc), candidate-id: candidate-id })
            candidate
            (if (> (get vote-count candidate) (get max-votes acc))
                (merge acc { max-votes: (get vote-count candidate), winner-id: candidate-id })
                acc
            )
            acc
        )
        acc
    )
)

;; Read-only functions

;; Get election details
(define-read-only (get-election (election-id uint))
    (map-get? elections { election-id: election-id })
)

;; Get candidate details
(define-read-only (get-candidate (election-id uint) (candidate-id uint))
    (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
)

;; Get vote details
(define-read-only (get-vote (vote-id uint))
    (map-get? votes { vote-id: vote-id })
)

;; Get voter ballot
(define-read-only (get-voter-ballot (voter-address principal) (election-id uint))
    (map-get? voter-ballots { voter-address: voter-address, election-id: election-id })
)

;; Get election results
(define-read-only (get-election-results (election-id uint))
    (map-get? election-results { election-id: election-id })
)

;; Check if voting is active
(define-read-only (is-voting-active)
    (var-get voting-active)
)

;; Get current election info
(define-read-only (get-current-election-info)
    {
        election-id: (var-get current-election-id),
        status: (var-get election-status),
        voting-active: (var-get voting-active),
        results-finalized: (var-get results-finalized)
    }
)

;; Get vote count for candidate
(define-read-only (get-candidate-votes (election-id uint) (candidate-id uint))
    (match (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
        candidate (some (get vote-count candidate))
        none
    )
)

;; Get total vote count
(define-read-only (get-total-votes)
    (var-get vote-counter)
)

;; Check if monitor is authorized
(define-read-only (is-monitor-authorized (monitor principal) (election-id uint))
    (default-to false (get authorized (map-get? election-monitors { monitor: monitor, election-id: election-id })))
)

;; Get vote verification status
(define-read-only (get-vote-verification (vote-id uint))
    (map-get? vote-verification { vote-id: vote-id })
)

