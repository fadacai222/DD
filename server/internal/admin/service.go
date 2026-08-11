package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/identity"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	adminLoginFailureWindow  = 15 * time.Minute
	adminLoginFailureLimit   = 10
	adminLoginIPFailureLimit = 50
	defaultSessionTTL        = 8 * time.Hour
	defaultIdleTTL           = 30 * time.Minute
	defaultChallengeTTL      = 5 * time.Minute
)

type Config struct {
	Pool         *pgxpool.Pool
	Hasher       *password.Hasher
	Secret       string
	Now          func() time.Time
	SessionTTL   time.Duration
	IdleTTL      time.Duration
	ChallengeTTL time.Duration
}

type Service struct {
	pool         *pgxpool.Pool
	hasher       *password.Hasher
	box          *secretBox
	dummyHash    string
	now          func() time.Time
	sessionTTL   time.Duration
	idleTTL      time.Duration
	challengeTTL time.Duration
}

type adminRow struct {
	ID              uuid.UUID
	Email           string
	PasswordHash    string
	Role            Role
	Status          string
	TOTPSecret      []byte
	TOTPEnabledAt   *time.Time
	TOTPLastCounter *int64
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, errors.New("admin postgres pool is required")
	}
	if config.Hasher == nil {
		return nil, errors.New("admin password hasher is required")
	}
	box, err := newSecretBox(config.Secret)
	if err != nil {
		return nil, err
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	sessionTTL := config.SessionTTL
	if sessionTTL <= 0 || sessionTTL > 24*time.Hour {
		sessionTTL = defaultSessionTTL
	}
	idleTTL := config.IdleTTL
	if idleTTL <= 0 || idleTTL > sessionTTL {
		idleTTL = defaultIdleTTL
		if idleTTL > sessionTTL {
			idleTTL = sessionTTL
		}
	}
	challengeTTL := config.ChallengeTTL
	if challengeTTL <= 0 || challengeTTL > 15*time.Minute {
		challengeTTL = defaultChallengeTTL
	}
	dummyHash, err := config.Hasher.Hash("dd-admin-dummy-password-never-used")
	if err != nil {
		return nil, fmt.Errorf("prepare admin password timing defense: %w", err)
	}
	return &Service{
		pool: config.Pool, hasher: config.Hasher, box: box, dummyHash: dummyHash,
		now: now, sessionTTL: sessionTTL, idleTTL: idleTTL, challengeTTL: challengeTTL,
	}, nil
}

func (service *Service) BootstrapAdmin(ctx context.Context, rawEmail, rawPassword string, role Role) (Identity, error) {
	email, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: invalid admin email", ErrInvalidInput)
	}
	if !role.Valid() {
		return Identity{}, fmt.Errorf("%w: invalid admin role", ErrInvalidInput)
	}
	if err := validateAdminPassword(rawPassword); err != nil {
		return Identity{}, err
	}
	hash, err := service.hasher.Hash(rawPassword)
	if err != nil {
		return Identity{}, fmt.Errorf("hash admin password: %w", err)
	}
	var id uuid.UUID
	err = service.pool.QueryRow(ctx, `
		INSERT INTO admin_accounts(email_normalized,password_hash,role,status,created_at,updated_at)
		VALUES($1,$2,$3,'ACTIVE',$4,$4)
		RETURNING id
	`, email, hash, string(role), service.now().UTC()).Scan(&id)
	if err != nil {
		if isUniqueViolation(err) {
			return Identity{}, ErrConflict
		}
		return Identity{}, fmt.Errorf("create admin account: %w", err)
	}
	return Identity{ID: id.String(), Email: email, Role: role}, nil
}

func validateAdminPassword(value string) error {
	length := utf8.RuneCountInString(value)
	if length < 14 {
		return fmt.Errorf("%w: admin password must contain at least 14 characters", ErrInvalidInput)
	}
	if len([]byte(value)) > 1024 {
		return fmt.Errorf("%w: admin password is too long", ErrInvalidInput)
	}
	return nil
}

func (service *Service) Login(ctx context.Context, rawEmail, rawPassword string, client ClientContext) (LoginResult, error) {
	now := service.now().UTC()
	email, normalizeErr := identity.NormalizeEmail(rawEmail)
	failureKey := strings.ToLower(strings.TrimSpace(rawEmail))
	if email != "" {
		failureKey = email
	}
	if len(failureKey) > 254 {
		failureKey = failureKey[:254]
	}
	if failureKey == "" {
		failureKey = "invalid@invalid.local"
	}
	clientIP := normalizeClientIP(client.RemoteAddress)
	if limited, err := service.loginRateLimited(ctx, failureKey, clientIP, now); err != nil {
		return LoginResult{}, err
	} else if limited {
		service.auditBestEffort(ctx, nil, nil, "", "ADMIN_LOGIN_RATE_LIMITED", "", "", "", map[string]any{"email": failureKey}, client)
		return LoginResult{}, ErrRateLimited
	}

	row := adminRow{}
	lookupErr := service.pool.QueryRow(ctx, `
		SELECT id,email_normalized,password_hash,role,status,totp_secret_ciphertext,totp_enabled_at,totp_last_counter
		FROM admin_accounts WHERE email_normalized=$1
	`, email).Scan(&row.ID, &row.Email, &row.PasswordHash, &row.Role, &row.Status, &row.TOTPSecret, &row.TOTPEnabledAt, &row.TOTPLastCounter)
	if normalizeErr != nil || errors.Is(lookupErr, pgx.ErrNoRows) {
		_, _ = service.hasher.Verify(service.dummyHash, rawPassword)
		service.recordLoginFailure(ctx, failureKey, clientIP, now)
		service.auditBestEffort(ctx, nil, nil, "", "ADMIN_LOGIN_FAILED", "", "", "", map[string]any{"email": failureKey}, client)
		return LoginResult{}, ErrInvalidCredentials
	}
	if lookupErr != nil {
		return LoginResult{}, fmt.Errorf("load admin account: %w", lookupErr)
	}
	if row.Status != "ACTIVE" {
		_, _ = service.hasher.Verify(row.PasswordHash, rawPassword)
		service.recordLoginFailure(ctx, failureKey, clientIP, now)
		service.auditBestEffort(ctx, &row.ID, nil, row.Role, "ADMIN_LOGIN_FAILED", "ADMIN", row.ID.String(), "", map[string]any{"disabled": true}, client)
		return LoginResult{}, ErrInvalidCredentials
	}
	verification, err := service.hasher.Verify(row.PasswordHash, rawPassword)
	if err != nil || !verification.Match {
		service.recordLoginFailure(ctx, failureKey, clientIP, now)
		service.auditBestEffort(ctx, &row.ID, nil, row.Role, "ADMIN_LOGIN_FAILED", "ADMIN", row.ID.String(), "", nil, client)
		return LoginResult{}, ErrInvalidCredentials
	}
	if verification.NeedsRehash {
		if rehashed, hashErr := service.hasher.Hash(rawPassword); hashErr == nil {
			_, _ = service.pool.Exec(ctx, `UPDATE admin_accounts SET password_hash=$2,updated_at=$3 WHERE id=$1`, row.ID, rehashed, now)
		}
	}
	_, _ = service.pool.Exec(ctx, `DELETE FROM admin_login_failures WHERE email_normalized=$1`, email)
	purpose := "MFA_VERIFY"
	enrollmentRequired := row.TOTPEnabledAt == nil || len(row.TOTPSecret) == 0
	if enrollmentRequired {
		purpose = "MFA_ENROLL"
	}
	challengeToken, challengeHash, err := newOpaqueToken("ddc_", challengeTokenBytes)
	if err != nil {
		return LoginResult{}, err
	}
	expiresAt := now.Add(service.challengeTTL)
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return LoginResult{}, fmt.Errorf("begin admin login challenge: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `UPDATE admin_auth_challenges SET consumed_at=$2 WHERE admin_id=$1 AND consumed_at IS NULL`, row.ID, now); err != nil {
		return LoginResult{}, fmt.Errorf("invalidate old admin challenge: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO admin_auth_challenges(admin_id,token_hash,purpose,created_at,expires_at,client_ip,user_agent)
		VALUES($1,$2,$3,$4,$5,$6,$7)
	`, row.ID, challengeHash, purpose, now, expiresAt, ipValue(clientIP), cleanUserAgent(client.UserAgent)); err != nil {
		return LoginResult{}, fmt.Errorf("create admin login challenge: %w", err)
	}
	if err := insertAudit(ctx, tx, &row.ID, nil, row.Role, "ADMIN_PASSWORD_ACCEPTED", "ADMIN", row.ID.String(), "", map[string]any{"mfaEnrollmentRequired": enrollmentRequired}, client, now); err != nil {
		return LoginResult{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return LoginResult{}, fmt.Errorf("commit admin login challenge: %w", err)
	}
	return LoginResult{
		ChallengeToken: challengeToken, ChallengeExpiresAt: expiresAt,
		MFARequired: true, EnrollmentRequired: enrollmentRequired,
	}, nil
}

func (service *Service) BeginMFAEnrollment(ctx context.Context, rawChallenge string) (Enrollment, error) {
	hash, err := hashOpaqueToken(rawChallenge, "ddc_", challengeTokenBytes)
	if err != nil {
		return Enrollment{}, ErrChallengeExpired
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return Enrollment{}, fmt.Errorf("begin mfa enrollment: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var adminID uuid.UUID
	var email string
	var pending []byte
	var attempts, maxAttempts int
	var expiresAt time.Time
	var consumedAt *time.Time
	err = tx.QueryRow(ctx, `
		SELECT c.admin_id,a.email_normalized,c.pending_totp_secret,c.attempts,c.max_attempts,c.expires_at,c.consumed_at
		FROM admin_auth_challenges c JOIN admin_accounts a ON a.id=c.admin_id AND a.status='ACTIVE'
		WHERE c.token_hash=$1 AND c.purpose='MFA_ENROLL' FOR UPDATE
	`, hash).Scan(&adminID, &email, &pending, &attempts, &maxAttempts, &expiresAt, &consumedAt)
	if errors.Is(err, pgx.ErrNoRows) || consumedAt != nil || !expiresAt.After(now) || attempts >= maxAttempts {
		return Enrollment{}, ErrChallengeExpired
	}
	if err != nil {
		return Enrollment{}, fmt.Errorf("load mfa enrollment challenge: %w", err)
	}
	var secret string
	if len(pending) > 0 {
		plain, decryptErr := service.box.decrypt(pending)
		if decryptErr != nil {
			return Enrollment{}, decryptErr
		}
		secret = string(plain)
	} else {
		secret, err = generateTOTPSecret()
		if err != nil {
			return Enrollment{}, err
		}
		pending, err = service.box.encrypt([]byte(secret))
		if err != nil {
			return Enrollment{}, err
		}
		if _, err := tx.Exec(ctx, `UPDATE admin_auth_challenges SET pending_totp_secret=$2 WHERE token_hash=$1`, hash, pending); err != nil {
			return Enrollment{}, fmt.Errorf("store mfa enrollment secret: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Enrollment{}, fmt.Errorf("commit mfa enrollment: %w", err)
	}
	return Enrollment{Secret: secret, OTPAuthURI: totpURI(email, secret)}, nil
}

func (service *Service) VerifyMFAEnrollment(ctx context.Context, rawChallenge, code string, client ClientContext) (IssuedSession, []string, error) {
	hash, err := hashOpaqueToken(rawChallenge, "ddc_", challengeTokenBytes)
	if err != nil {
		return IssuedSession{}, nil, ErrChallengeExpired
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return IssuedSession{}, nil, fmt.Errorf("begin mfa enrollment verification: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	row, pending, challengeID, attempts, maxAttempts, expiresAt, consumedAt, err := loadChallengeForUpdate(ctx, tx, hash, "MFA_ENROLL")
	if errors.Is(err, pgx.ErrNoRows) || consumedAt != nil || !expiresAt.After(now) || attempts >= maxAttempts || len(pending) == 0 {
		return IssuedSession{}, nil, ErrChallengeExpired
	}
	if err != nil {
		return IssuedSession{}, nil, fmt.Errorf("load enrollment verification challenge: %w", err)
	}
	plain, err := service.box.decrypt(pending)
	if err != nil {
		return IssuedSession{}, nil, err
	}
	counter, valid := verifyTOTP(string(plain), code, now)
	if !valid {
		_ = incrementChallengeAttempt(ctx, tx, challengeID)
		_ = tx.Commit(ctx)
		return IssuedSession{}, nil, ErrInvalidMFA
	}
	encryptedSecret, err := service.box.encrypt(plain)
	if err != nil {
		return IssuedSession{}, nil, err
	}
	result, err := tx.Exec(ctx, `
		UPDATE admin_accounts
		SET totp_secret_ciphertext=$2,totp_enabled_at=$3,totp_last_counter=$4,updated_at=$3
		WHERE id=$1 AND status='ACTIVE' AND totp_enabled_at IS NULL
	`, row.ID, encryptedSecret, now, counter)
	if err != nil {
		return IssuedSession{}, nil, fmt.Errorf("enable admin mfa: %w", err)
	}
	if result.RowsAffected() != 1 {
		return IssuedSession{}, nil, ErrConflict
	}
	codes, hashes, err := newRecoveryCodes()
	if err != nil {
		return IssuedSession{}, nil, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM admin_recovery_codes WHERE admin_id=$1`, row.ID); err != nil {
		return IssuedSession{}, nil, fmt.Errorf("clear old admin recovery codes: %w", err)
	}
	for _, recoveryHash := range hashes {
		if _, err := tx.Exec(ctx, `INSERT INTO admin_recovery_codes(admin_id,code_hash,created_at) VALUES($1,$2,$3)`, row.ID, recoveryHash, now); err != nil {
			return IssuedSession{}, nil, fmt.Errorf("store admin recovery code: %w", err)
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_auth_challenges SET consumed_at=$2 WHERE id=$1`, challengeID, now); err != nil {
		return IssuedSession{}, nil, fmt.Errorf("consume admin mfa enrollment challenge: %w", err)
	}
	issued, err := service.createSessionTx(ctx, tx, row, client, now)
	if err != nil {
		return IssuedSession{}, nil, err
	}
	if err := insertAudit(ctx, tx, &row.ID, &issued.SessionIDUUID, row.Role, "ADMIN_MFA_ENROLLED", "ADMIN", row.ID.String(), "", map[string]any{"recoveryCodeCount": len(codes)}, client, now); err != nil {
		return IssuedSession{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return IssuedSession{}, nil, fmt.Errorf("commit admin mfa enrollment: %w", err)
	}
	return issued.IssuedSession, codes, nil
}

func (service *Service) VerifyMFA(ctx context.Context, rawChallenge, code, recoveryCode string, client ClientContext) (IssuedSession, error) {
	hash, err := hashOpaqueToken(rawChallenge, "ddc_", challengeTokenBytes)
	if err != nil {
		return IssuedSession{}, ErrChallengeExpired
	}
	if (strings.TrimSpace(code) == "") == (strings.TrimSpace(recoveryCode) == "") {
		return IssuedSession{}, ErrInvalidMFA
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return IssuedSession{}, fmt.Errorf("begin mfa verification: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	row, _, challengeID, attempts, maxAttempts, expiresAt, consumedAt, err := loadChallengeForUpdate(ctx, tx, hash, "MFA_VERIFY")
	if errors.Is(err, pgx.ErrNoRows) || consumedAt != nil || !expiresAt.After(now) || attempts >= maxAttempts {
		return IssuedSession{}, ErrChallengeExpired
	}
	if err != nil {
		return IssuedSession{}, fmt.Errorf("load mfa challenge: %w", err)
	}
	valid := false
	usedRecovery := false
	if strings.TrimSpace(code) != "" {
		plain, decryptErr := service.box.decrypt(row.TOTPSecret)
		if decryptErr != nil {
			return IssuedSession{}, decryptErr
		}
		counter, matched := verifyTOTP(string(plain), code, now)
		if matched {
			result, updateErr := tx.Exec(ctx, `
				UPDATE admin_accounts SET totp_last_counter=$2,updated_at=$3
				WHERE id=$1 AND status='ACTIVE' AND (totp_last_counter IS NULL OR totp_last_counter < $2)
			`, row.ID, counter, now)
			if updateErr != nil {
				return IssuedSession{}, fmt.Errorf("record admin totp counter: %w", updateErr)
			}
			valid = result.RowsAffected() == 1
		}
	} else {
		recoveryHash := hashRecoveryCode(recoveryCode)
		result, updateErr := tx.Exec(ctx, `
			UPDATE admin_recovery_codes SET used_at=$3
			WHERE admin_id=$1 AND code_hash=$2 AND used_at IS NULL
		`, row.ID, recoveryHash, now)
		if updateErr != nil {
			return IssuedSession{}, fmt.Errorf("consume admin recovery code: %w", updateErr)
		}
		valid = result.RowsAffected() == 1
		usedRecovery = valid
	}
	if !valid {
		_ = incrementChallengeAttempt(ctx, tx, challengeID)
		_ = tx.Commit(ctx)
		return IssuedSession{}, ErrInvalidMFA
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_auth_challenges SET consumed_at=$2 WHERE id=$1`, challengeID, now); err != nil {
		return IssuedSession{}, fmt.Errorf("consume admin mfa challenge: %w", err)
	}
	issued, err := service.createSessionTx(ctx, tx, row, client, now)
	if err != nil {
		return IssuedSession{}, err
	}
	action := "ADMIN_MFA_VERIFIED"
	if usedRecovery {
		action = "ADMIN_RECOVERY_CODE_USED"
	}
	if err := insertAudit(ctx, tx, &row.ID, &issued.SessionIDUUID, row.Role, action, "ADMIN", row.ID.String(), "", nil, client, now); err != nil {
		return IssuedSession{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return IssuedSession{}, fmt.Errorf("commit admin mfa verification: %w", err)
	}
	return issued.IssuedSession, nil
}

type createdSession struct {
	IssuedSession
	SessionIDUUID uuid.UUID
}

func (service *Service) createSessionTx(ctx context.Context, tx pgx.Tx, row adminRow, client ClientContext, now time.Time) (createdSession, error) {
	raw, tokenHash, err := newOpaqueToken("dda_", sessionTokenBytes)
	if err != nil {
		return createdSession{}, err
	}
	expiresAt := now.Add(service.sessionTTL)
	idleExpiresAt := now.Add(service.idleTTL)
	if idleExpiresAt.After(expiresAt) {
		idleExpiresAt = expiresAt
	}
	sessionID := uuid.New()
	if _, err := tx.Exec(ctx, `
		INSERT INTO admin_sessions(id,admin_id,token_hash,created_at,last_seen_at,idle_expires_at,expires_at,client_ip,user_agent)
		VALUES($1,$2,$3,$4,$4,$5,$6,$7,$8)
	`, sessionID, row.ID, tokenHash, now, idleExpiresAt, expiresAt, ipValue(normalizeClientIP(client.RemoteAddress)), cleanUserAgent(client.UserAgent)); err != nil {
		return createdSession{}, fmt.Errorf("create admin session: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_accounts SET last_login_at=$2,updated_at=$2 WHERE id=$1`, row.ID, now); err != nil {
		return createdSession{}, fmt.Errorf("update admin login time: %w", err)
	}
	return createdSession{
		IssuedSession: IssuedSession{
			SessionResult: SessionResult{
				Admin:     Identity{ID: row.ID.String(), Email: row.Email, Role: row.Role},
				SessionID: sessionID.String(), ExpiresAt: expiresAt, IdleExpiresAt: idleExpiresAt,
				CSRFToken: service.box.csrfToken(raw),
			},
			Token: raw,
		},
		SessionIDUUID: sessionID,
	}, nil
}

func (service *Service) AuthenticateSession(ctx context.Context, rawToken string) (Principal, SessionResult, error) {
	hash, err := hashOpaqueToken(rawToken, "dda_", sessionTokenBytes)
	if err != nil {
		return Principal{}, SessionResult{}, ErrUnauthorized
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return Principal{}, SessionResult{}, fmt.Errorf("begin admin session authentication: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var principal Principal
	var createdAt, lastSeenAt, idleExpiresAt, expiresAt time.Time
	var revokedAt *time.Time
	err = tx.QueryRow(ctx, `
		SELECT a.id,s.id,a.email_normalized,a.role,s.created_at,s.last_seen_at,s.idle_expires_at,s.expires_at,s.revoked_at
		FROM admin_sessions s JOIN admin_accounts a ON a.id=s.admin_id AND a.status='ACTIVE'
		WHERE s.token_hash=$1 FOR UPDATE OF s
	`, hash).Scan(&principal.AdminID, &principal.SessionID, &principal.Email, &principal.Role, &createdAt, &lastSeenAt, &idleExpiresAt, &expiresAt, &revokedAt)
	if errors.Is(err, pgx.ErrNoRows) || revokedAt != nil || !expiresAt.After(now) || !idleExpiresAt.After(now) {
		if err == nil && revokedAt == nil {
			_, _ = tx.Exec(ctx, `UPDATE admin_sessions SET revoked_at=$2,revoke_reason='EXPIRED' WHERE id=$1 AND revoked_at IS NULL`, principal.SessionID, now)
			_ = tx.Commit(ctx)
		}
		return Principal{}, SessionResult{}, ErrUnauthorized
	}
	if err != nil {
		return Principal{}, SessionResult{}, fmt.Errorf("load admin session: %w", err)
	}
	newIdleExpiry := now.Add(service.idleTTL)
	if newIdleExpiry.After(expiresAt) {
		newIdleExpiry = expiresAt
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_sessions SET last_seen_at=$2,idle_expires_at=$3 WHERE id=$1`, principal.SessionID, now, newIdleExpiry); err != nil {
		return Principal{}, SessionResult{}, fmt.Errorf("touch admin session: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Principal{}, SessionResult{}, fmt.Errorf("commit admin session touch: %w", err)
	}
	principal.ExpiresAt = expiresAt
	return principal, SessionResult{
		Admin:     Identity{ID: principal.AdminID.String(), Email: principal.Email, Role: principal.Role},
		SessionID: principal.SessionID.String(), ExpiresAt: expiresAt, IdleExpiresAt: newIdleExpiry,
		CSRFToken: service.box.csrfToken(rawToken),
	}, nil
}

func (service *Service) VerifyCSRF(rawSessionToken, provided string) bool {
	return service.box.verifyCSRF(rawSessionToken, provided)
}

func (service *Service) ListSessions(ctx context.Context, principal Principal) ([]SessionInfo, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT id,created_at,last_seen_at,idle_expires_at,expires_at,revoked_at,COALESCE(client_ip::text,''),user_agent
		FROM admin_sessions WHERE admin_id=$1 ORDER BY created_at DESC LIMIT 50
	`, principal.AdminID)
	if err != nil {
		return nil, fmt.Errorf("list admin sessions: %w", err)
	}
	defer rows.Close()
	result := make([]SessionInfo, 0)
	for rows.Next() {
		var item SessionInfo
		var id uuid.UUID
		if err := rows.Scan(&id, &item.CreatedAt, &item.LastSeenAt, &item.IdleExpiresAt, &item.ExpiresAt, &item.RevokedAt, &item.ClientIP, &item.UserAgent); err != nil {
			return nil, fmt.Errorf("scan admin session: %w", err)
		}
		item.ID = id.String()
		item.Current = id == principal.SessionID
		result = append(result, item)
	}
	return result, rows.Err()
}

func (service *Service) RevokeSession(ctx context.Context, principal Principal, sessionID uuid.UUID, reason string, client ClientContext) error {
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin admin session revoke: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	result, err := tx.Exec(ctx, `
		UPDATE admin_sessions SET revoked_at=COALESCE(revoked_at,$3),revoke_reason=COALESCE(revoke_reason,$4)
		WHERE id=$1 AND admin_id=$2
	`, sessionID, principal.AdminID, now, normalizedReason(reason, "ADMIN_REVOKED"))
	if err != nil {
		return fmt.Errorf("revoke admin session: %w", err)
	}
	if result.RowsAffected() != 1 {
		return ErrNotFound
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "ADMIN_SESSION_REVOKED", "ADMIN_SESSION", sessionID.String(), reason, nil, client, now); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit admin session revoke: %w", err)
	}
	return nil
}

func (service *Service) RegenerateRecoveryCodes(ctx context.Context, principal Principal, code string, client ClientContext) ([]string, error) {
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin recovery code regeneration: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var encrypted []byte
	var lastCounter *int64
	err = tx.QueryRow(ctx, `SELECT totp_secret_ciphertext,totp_last_counter FROM admin_accounts WHERE id=$1 AND status='ACTIVE' FOR UPDATE`, principal.AdminID).Scan(&encrypted, &lastCounter)
	if errors.Is(err, pgx.ErrNoRows) || len(encrypted) == 0 {
		return nil, ErrUnauthorized
	}
	if err != nil {
		return nil, fmt.Errorf("load admin mfa for recovery regeneration: %w", err)
	}
	plain, err := service.box.decrypt(encrypted)
	if err != nil {
		return nil, err
	}
	counter, valid := verifyTOTP(string(plain), code, now)
	if !valid || (lastCounter != nil && counter <= *lastCounter) {
		return nil, ErrInvalidMFA
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_accounts SET totp_last_counter=$2,updated_at=$3 WHERE id=$1`, principal.AdminID, counter, now); err != nil {
		return nil, fmt.Errorf("record recovery regeneration totp counter: %w", err)
	}
	codes, hashes, err := newRecoveryCodes()
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM admin_recovery_codes WHERE admin_id=$1`, principal.AdminID); err != nil {
		return nil, fmt.Errorf("delete old recovery codes: %w", err)
	}
	for _, recoveryHash := range hashes {
		if _, err := tx.Exec(ctx, `INSERT INTO admin_recovery_codes(admin_id,code_hash,created_at) VALUES($1,$2,$3)`, principal.AdminID, recoveryHash, now); err != nil {
			return nil, fmt.Errorf("store regenerated recovery code: %w", err)
		}
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "ADMIN_RECOVERY_CODES_REGENERATED", "ADMIN", principal.AdminID.String(), "", map[string]any{"count": len(codes)}, client, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit recovery code regeneration: %w", err)
	}
	return codes, nil
}

func (service *Service) loginRateLimited(ctx context.Context, email, clientIP string, now time.Time) (bool, error) {
	var emailCount, ipCount int
	err := service.pool.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE email_normalized=$2),
			count(*) FILTER (WHERE $3::inet IS NOT NULL AND client_ip=$3::inet)
		FROM admin_login_failures
		WHERE attempted_at >= $1
	`, now.Add(-adminLoginFailureWindow), email, ipValue(clientIP)).Scan(&emailCount, &ipCount)
	if err != nil {
		return false, fmt.Errorf("check admin login rate limit: %w", err)
	}
	return emailCount >= adminLoginFailureLimit || (clientIP != "" && ipCount >= adminLoginIPFailureLimit), nil
}

func (service *Service) recordLoginFailure(ctx context.Context, email, clientIP string, now time.Time) {
	_, _ = service.pool.Exec(ctx, `INSERT INTO admin_login_failures(email_normalized,client_ip,attempted_at) VALUES($1,$2,$3)`, email, ipValue(clientIP), now)
	_, _ = service.pool.Exec(ctx, `DELETE FROM admin_login_failures WHERE attempted_at < $1`, now.Add(-24*time.Hour))
}

func loadChallengeForUpdate(ctx context.Context, tx pgx.Tx, hash []byte, purpose string) (adminRow, []byte, uuid.UUID, int, int, time.Time, *time.Time, error) {
	var row adminRow
	var pending []byte
	var challengeID uuid.UUID
	var attempts, maxAttempts int
	var expiresAt time.Time
	var consumedAt *time.Time
	err := tx.QueryRow(ctx, `
		SELECT a.id,a.email_normalized,a.password_hash,a.role,a.status,a.totp_secret_ciphertext,a.totp_enabled_at,a.totp_last_counter,
		       c.pending_totp_secret,c.id,c.attempts,c.max_attempts,c.expires_at,c.consumed_at
		FROM admin_auth_challenges c JOIN admin_accounts a ON a.id=c.admin_id AND a.status='ACTIVE'
		WHERE c.token_hash=$1 AND c.purpose=$2 FOR UPDATE OF c,a
	`, hash, purpose).Scan(&row.ID, &row.Email, &row.PasswordHash, &row.Role, &row.Status, &row.TOTPSecret, &row.TOTPEnabledAt, &row.TOTPLastCounter,
		&pending, &challengeID, &attempts, &maxAttempts, &expiresAt, &consumedAt)
	return row, pending, challengeID, attempts, maxAttempts, expiresAt, consumedAt, err
}

func incrementChallengeAttempt(ctx context.Context, tx pgx.Tx, challengeID uuid.UUID) error {
	_, err := tx.Exec(ctx, `UPDATE admin_auth_challenges SET attempts=LEAST(attempts+1,max_attempts) WHERE id=$1`, challengeID)
	return err
}

func (service *Service) auditBestEffort(ctx context.Context, actorAdminID, sessionID *uuid.UUID, role Role, action, targetType, targetID, reason string, detail map[string]any, client ClientContext) {
	_, _ = service.pool.Exec(ctx, auditInsertSQL(), actorAdminID, sessionID, nullableRole(role), action, nullableString(targetType), nullableString(targetID), nullableString(reason), mustJSON(detail), ipValue(normalizeClientIP(client.RemoteAddress)), cleanUserAgent(client.UserAgent), service.now().UTC())
}

func insertAudit(ctx context.Context, tx pgx.Tx, actorAdminID, sessionID *uuid.UUID, role Role, action, targetType, targetID, reason string, detail map[string]any, client ClientContext, now time.Time) error {
	_, err := tx.Exec(ctx, auditInsertSQL(), actorAdminID, sessionID, nullableRole(role), action, nullableString(targetType), nullableString(targetID), nullableString(reason), mustJSON(detail), ipValue(normalizeClientIP(client.RemoteAddress)), cleanUserAgent(client.UserAgent), now)
	if err != nil {
		return fmt.Errorf("write admin audit event: %w", err)
	}
	return nil
}

func auditInsertSQL() string {
	return `INSERT INTO admin_audit_events(actor_admin_id,session_id,actor_role,action,target_type,target_id,reason,detail,client_ip,user_agent,created_at)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10,$11)`
}

func mustJSON(value map[string]any) string {
	if value == nil {
		return `{}`
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return `{}`
	}
	return string(raw)
}

func normalizeClientIP(remoteAddress string) string {
	value := strings.TrimSpace(remoteAddress)
	if host, _, err := net.SplitHostPort(value); err == nil {
		value = host
	}
	value = strings.Trim(value, "[]")
	ip := net.ParseIP(value)
	if ip == nil {
		return ""
	}
	return ip.String()
}

func ipValue(ip string) any {
	if ip == "" {
		return nil
	}
	return ip
}

func cleanUserAgent(value string) string {
	value = strings.TrimSpace(value)
	if utf8.RuneCountInString(value) <= 500 {
		return value
	}
	runes := []rune(value)
	return string(runes[:500])
}

func normalizedReason(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	if utf8.RuneCountInString(value) > 64 {
		runes := []rune(value)
		value = string(runes[:64])
	}
	return value
}

func nullableString(value string) any {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	return value
}

func nullableRole(role Role) any {
	if role == "" {
		return nil
	}
	return string(role)
}

func isUniqueViolation(err error) bool {
	type sqlStateCarrier interface{ SQLState() string }
	var carrier sqlStateCarrier
	return errors.As(err, &carrier) && carrier.SQLState() == "23505"
}
