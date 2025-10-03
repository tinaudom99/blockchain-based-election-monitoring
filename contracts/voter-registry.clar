;; voter-registry
;; Smart contract to register and verify eligible voters

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_ALREADY_EXISTS (err u102))
(define-constant ERR_UNAUTHORIZED (err u103))
(define-constant ERR_INVALID_STATUS (err u104))
(define-constant ERR_REGISTRATION_CLOSED (err u105))
(define-constant ERR_VOTING_ACTIVE (err u106))
(define-constant ERR_INVALID_CREDENTIAL (err u107))
(define-constant ERR_ALREADY_VOTED (err u108))

;; Registration statuses
(define-constant STATUS_PENDING "pending")
(define-constant STATUS_VERIFIED "verified")
(define-constant STATUS_REJECTED "rejected")
(define-constant STATUS_SUSPENDED "suspended")

;; Election phases
(define-constant PHASE_REGISTRATION "registration")
(define-constant PHASE_VERIFICATION "verification")
(define-constant PHASE_VOTING "voting")
(define-constant PHASE_COMPLETED "completed")

;; Data Variables
(define-data-var voter-counter uint u0)
(define-data-var registration-open bool true)
(define-data-var current-election-id uint u0)
(define-data-var election-phase (string-ascii 20) PHASE_REGISTRATION)
(define-data-var registration-deadline uint u0)
(define-data-var voting-start uint u0)
(define-data-var voting-end uint u0)

;; Data Maps
(define-map registered-voters
    { voter-id: uint }
    {
        voter-address: principal,
        identity-hash: (buff 32),
        registration-date: uint,
        verification-date: (optional uint),
        status: (string-ascii 20),
        metadata: (string-ascii 256),
        has-voted: bool,
        vote-timestamp: (optional uint),
        election-id: uint
    }
)

(define-map voter-by-address
    { voter-address: principal }
    { voter-id: uint, election-id: uint }
)

(define-map voter-by-identity
    { identity-hash: (buff 32) }
    { voter-id: uint, election-id: uint }
)

(define-map election-administrators
    { admin: principal }
    { authorized: bool, permissions: (string-ascii 64) }
)

(define-map election-stats
    { election-id: uint }
    {
        total-registered: uint,
        total-verified: uint,
        total-voted: uint,
        registration-start: uint,
        registration-end: uint,
        voting-start: uint,
        voting-end: uint,
        election-title: (string-ascii 128)
    }
)

(define-map verification-queue
    { position: uint }
    { voter-id: uint }
)

(define-map voter-credentials
    { voter-id: uint }
    {
        credential-hash: (buff 32),
        issued-date: uint,
        expires-date: uint,
        revoked: bool
    }
)

;; Public Functions

;; Register a new voter
(define-public (register-voter 
    (identity-hash (buff 32))
    (metadata (string-ascii 256)))
    (let (
        (voter-id (+ (var-get voter-counter) u1))
        (current-time stacks-block-height)
        (current-election (var-get current-election-id))
    )
        ;; Check if registration is open
        (asserts! (var-get registration-open) ERR_REGISTRATION_CLOSED)
        ;; Check if in registration phase
        (asserts! (is-eq (var-get election-phase) PHASE_REGISTRATION) ERR_VOTING_ACTIVE)
        ;; Check if voter address is not already registered
        (asserts! (is-none (map-get? voter-by-address { voter-address: tx-sender })) ERR_ALREADY_EXISTS)
        ;; Check if identity hash is not already used
        (asserts! (is-none (map-get? voter-by-identity { identity-hash: identity-hash })) ERR_ALREADY_EXISTS)
        
        ;; Create voter record
        (map-set registered-voters
            { voter-id: voter-id }
            {
                voter-address: tx-sender,
                identity-hash: identity-hash,
                registration-date: current-time,
                verification-date: none,
                status: STATUS_PENDING,
                metadata: metadata,
                has-voted: false,
                vote-timestamp: none,
                election-id: current-election
            }
        )
        
        ;; Map address to voter ID
        (map-set voter-by-address
            { voter-address: tx-sender }
            { voter-id: voter-id, election-id: current-election }
        )
        
        ;; Map identity hash to voter ID
        (map-set voter-by-identity
            { identity-hash: identity-hash }
            { voter-id: voter-id, election-id: current-election }
        )
        
        ;; Update election stats
        (let (
            (current-stats (default-to 
                { total-registered: u0, total-verified: u0, total-voted: u0, 
                  registration-start: current-time, registration-end: u0, 
                  voting-start: u0, voting-end: u0, election-title: "" }
                (map-get? election-stats { election-id: current-election })
            ))
        )
            (map-set election-stats
                { election-id: current-election }
                (merge current-stats { 
                    total-registered: (+ (get total-registered current-stats) u1)
                })
            )
        )
        
        ;; Update voter counter
        (var-set voter-counter voter-id)
        
        (ok voter-id)
    )
)

;; Verify a registered voter (admin only)
(define-public (verify-voter (voter-id uint))
    (let (
        (voter-data (unwrap! (map-get? registered-voters { voter-id: voter-id }) ERR_NOT_FOUND))
        (current-time stacks-block-height)
    )
        ;; Check if sender is authorized admin
        (asserts! (default-to false (get authorized (map-get? election-administrators { admin: tx-sender }))) ERR_UNAUTHORIZED)
        ;; Check if voter is in pending status
        (asserts! (is-eq (get status voter-data) STATUS_PENDING) ERR_INVALID_STATUS)
        
        ;; Update voter status to verified
        (map-set registered-voters
            { voter-id: voter-id }
            (merge voter-data {
                status: STATUS_VERIFIED,
                verification-date: (some current-time)
            })
        )
        
        ;; Update election stats
        (let (
            (current-election (get election-id voter-data))
            (current-stats (unwrap-panic (map-get? election-stats { election-id: current-election })))
        )
            (map-set election-stats
                { election-id: current-election }
                (merge current-stats {
                    total-verified: (+ (get total-verified current-stats) u1)
                })
            )
        )
        
        ;; Issue voter credential
        (let (
            (credential-hash (keccak256 (concat (unwrap-panic (to-consensus-buff? voter-id)) 
                                                (unwrap-panic (to-consensus-buff? current-time)))))
        )
            (map-set voter-credentials
                { voter-id: voter-id }
                {
                    credential-hash: credential-hash,
                    issued-date: current-time,
                    expires-date: (+ current-time u5256000), ;; ~2 months
                    revoked: false
                }
            )
        )
        
        (ok true)
    )
)

;; Reject a voter registration (admin only)
(define-public (reject-voter (voter-id uint) (reason (string-ascii 256)))
    (let (
        (voter-data (unwrap! (map-get? registered-voters { voter-id: voter-id }) ERR_NOT_FOUND))
    )
        ;; Check if sender is authorized admin
        (asserts! (default-to false (get authorized (map-get? election-administrators { admin: tx-sender }))) ERR_UNAUTHORIZED)
        ;; Check if voter is in pending status
        (asserts! (is-eq (get status voter-data) STATUS_PENDING) ERR_INVALID_STATUS)
        
        ;; Update voter status to rejected
        (map-set registered-voters
            { voter-id: voter-id }
            (merge voter-data {
                status: STATUS_REJECTED,
                metadata: reason
            })
        )
        
        (ok true)
    )
)

;; Suspend a verified voter (admin only)
(define-public (suspend-voter (voter-id uint) (reason (string-ascii 256)))
    (let (
        (voter-data (unwrap! (map-get? registered-voters { voter-id: voter-id }) ERR_NOT_FOUND))
    )
        ;; Check if sender is authorized admin
        (asserts! (default-to false (get authorized (map-get? election-administrators { admin: tx-sender }))) ERR_UNAUTHORIZED)
        ;; Check if voter is verified
        (asserts! (is-eq (get status voter-data) STATUS_VERIFIED) ERR_INVALID_STATUS)
        
        ;; Update voter status to suspended
        (map-set registered-voters
            { voter-id: voter-id }
            (merge voter-data {
                status: STATUS_SUSPENDED,
                metadata: reason
            })
        )
        
        ;; Revoke credential
        (match (map-get? voter-credentials { voter-id: voter-id })
            credential (map-set voter-credentials
                { voter-id: voter-id }
                (merge credential { revoked: true })
            )
            true
        )
        
        (ok true)
    )
)

;; Mark voter as having voted (called by ballot contract)
(define-public (mark-as-voted (voter-address principal))
    (let (
        (voter-ref (unwrap! (map-get? voter-by-address { voter-address: voter-address }) ERR_NOT_FOUND))
        (voter-id (get voter-id voter-ref))
        (voter-data (unwrap! (map-get? registered-voters { voter-id: voter-id }) ERR_NOT_FOUND))
        (current-time stacks-block-height)
    )
        ;; Check if voter is verified
        (asserts! (is-eq (get status voter-data) STATUS_VERIFIED) ERR_INVALID_STATUS)
        ;; Check if voter hasn't already voted
        (asserts! (not (get has-voted voter-data)) ERR_ALREADY_VOTED)
        
        ;; Mark as voted
        (map-set registered-voters
            { voter-id: voter-id }
            (merge voter-data {
                has-voted: true,
                vote-timestamp: (some current-time)
            })
        )
        
        ;; Update election stats
        (let (
            (current-election (get election-id voter-data))
            (current-stats (unwrap-panic (map-get? election-stats { election-id: current-election })))
        )
            (map-set election-stats
                { election-id: current-election }
                (merge current-stats {
                    total-voted: (+ (get total-voted current-stats) u1)
                })
            )
        )
        
        (ok true)
    )
)

;; Start new election (owner only)
(define-public (start-new-election 
    (election-title (string-ascii 128))
    (registration-period uint)
    (voting-period uint))
    (let (
        (current-time stacks-block-height)
        (new-election-id (+ (var-get current-election-id) u1))
        (registration-end-time (+ current-time registration-period))
        (voting-start-time (+ registration-end-time u1440)) ;; 1 day buffer
        (voting-end-time (+ voting-start-time voting-period))
    )
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        
        ;; Initialize new election
        (var-set current-election-id new-election-id)
        (var-set election-phase PHASE_REGISTRATION)
        (var-set registration-open true)
        (var-set registration-deadline registration-end-time)
        (var-set voting-start voting-start-time)
        (var-set voting-end voting-end-time)
        (var-set voter-counter u0)
        
        ;; Create election stats record
        (map-set election-stats
            { election-id: new-election-id }
            {
                total-registered: u0,
                total-verified: u0,
                total-voted: u0,
                registration-start: current-time,
                registration-end: registration-end-time,
                voting-start: voting-start-time,
                voting-end: voting-end-time,
                election-title: election-title
            }
        )
        
        (ok new-election-id)
    )
)

;; Close registration (owner only)
(define-public (close-registration)
    (begin
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        
        ;; Update phase and close registration
        (var-set registration-open false)
        (var-set election-phase PHASE_VERIFICATION)
        
        (ok true)
    )
)

;; Start voting phase (owner only)
(define-public (start-voting)
    (begin
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        ;; Check if in verification phase
        (asserts! (is-eq (var-get election-phase) PHASE_VERIFICATION) ERR_INVALID_STATUS)
        
        ;; Update phase to voting
        (var-set election-phase PHASE_VOTING)
        
        (ok true)
    )
)

;; Authorize election administrator (owner only)
(define-public (authorize-admin (admin principal) (permissions (string-ascii 64)))
    (begin
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        
        ;; Authorize admin
        (map-set election-administrators
            { admin: admin }
            { authorized: true, permissions: permissions }
        )
        
        (ok true)
    )
)

;; Revoke administrator privileges (owner only)
(define-public (revoke-admin (admin principal))
    (begin
        ;; Check if sender is contract owner
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        
        ;; Revoke admin
        (map-set election-administrators
            { admin: admin }
            { authorized: false, permissions: "" }
        )
        
        (ok true)
    )
)

;; Read-only functions

;; Get voter details by ID
(define-read-only (get-voter (voter-id uint))
    (map-get? registered-voters { voter-id: voter-id })
)

;; Get voter by address
(define-read-only (get-voter-by-address (voter-address principal))
    (match (map-get? voter-by-address { voter-address: voter-address })
        voter-ref (map-get? registered-voters { voter-id: (get voter-id voter-ref) })
        none
    )
)

;; Check if voter is eligible to vote
(define-read-only (is-voter-eligible (voter-address principal))
    (match (get-voter-by-address voter-address)
        voter-data
        (and
            (is-eq (get status voter-data) STATUS_VERIFIED)
            (not (get has-voted voter-data))
            (is-eq (var-get election-phase) PHASE_VOTING)
        )
        false
    )
)

;; Get voter credential
(define-read-only (get-voter-credential (voter-id uint))
    (map-get? voter-credentials { voter-id: voter-id })
)

;; Get election statistics
(define-read-only (get-election-stats (election-id uint))
    (map-get? election-stats { election-id: election-id })
)

;; Get current election info
(define-read-only (get-current-election)
    {
        election-id: (var-get current-election-id),
        phase: (var-get election-phase),
        registration-open: (var-get registration-open),
        registration-deadline: (var-get registration-deadline),
        voting-start: (var-get voting-start),
        voting-end: (var-get voting-end)
    }
)

;; Check if admin is authorized
(define-read-only (is-admin-authorized (admin principal))
    (default-to false (get authorized (map-get? election-administrators { admin: admin })))
)

;; Get total voter count
(define-read-only (get-voter-count)
    (var-get voter-counter)
)

