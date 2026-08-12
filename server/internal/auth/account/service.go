package account

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/emailcode"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/auth/registration"
	"example.com/selfhosted-im/server/internal/auth/session"
	"example.com/selfhosted-im/server/internal/identity"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrUnavailable          = errors.New("authentication service unavailable")
	ErrRegistrationDisabled = errors.New("registration is disabled")
	ErrRateLimited          = errors.New("verification code rate limited")
	ErrInvalidCode          = errors.New("verification code is invalid")
	ErrEmailExists          = errors.New("email is already registered")
	ErrHandleExists         = errors.New("handle is already registered")
	ErrInvalidCredentials   = errors.New("invalid email or password")
	ErrInvalidRefreshToken  = errors.New("refresh token is invalid")
	ErrRefreshReuse         = errors.New("refresh token reuse detected")
)

const (
	registrationCodeTTL      = 10 * time.Minute
	registrationCodeCooldown = 60 * time.Second
	registrationCodeWindow   = 15 * time.Minute
	registrationCodeMaxBurst = 5
)

type Mailer interface {
	SendVerificationCode(ctx context.Context, to, purpose, code string) error
}

type Config struct {
	Pool             *pgxpool.Pool
	Codec            *emailcode.Codec
	Hasher           *password.Hasher
	Sessions         *session.Manager
	Mailer           Mailer
	RegistrationMode string
	Now              func() time.Time
}

type Service struct {
	pool              *pgxpool.Pool
	codec             *emailcode.Codec
	hasher            *password.Hasher
	sessions          *session.Manager
	mailer            Mailer
	registrationMode  string
	now               func() time.Time
	dummyPasswordHash string
}

type User struct {
	ID          string `json:"id"`
	Email       string `json:"email"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
}

type Device struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"appVersion"`
}

type Tokens struct {
	AccessToken      string    `json:"accessToken"`
	AccessExpiresAt  time.Time `json:"accessExpiresAt"`
	RefreshToken     string    `json:"refreshToken"`
	RefreshExpiresAt time.Time `json:"refreshExpiresAt"`
}

type AuthSession struct {
	User   User   `json:"user"`
	Device Device `json:"device"`
	Tokens Tokens `json:"tokens"`
}

type LoginInput struct {
	Email    string                   `json:"email"`
	Password string                   `json:"password"`
	Device   registration.DeviceInput `json:"device"`
}

func NewService(config Config) (*Service, error) {
	mode := strings.ToLower(strings.TrimSpace(config.RegistrationMode))
	if config.Pool == nil || config.Hasher == nil || config.Sessions == nil {
		return nil, ErrUnavailable
	}
	if mode == "open" && (config.Codec == nil || config.Mailer == nil) {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	dummyHash, err := config.Hasher.Hash("dummy-password-value-only-for-timing")
	if err != nil {
		return nil, fmt.Errorf("create password timing hash: %w", err)
	}
	return &Service{
		pool:              config.Pool,
		codec:             config.Codec,
		hasher:            config.Hasher,
		sessions:          config.Sessions,
		mailer:            config.Mailer,
		registrationMode:  mode,
		now:               now,
		dummyPasswordHash: dummyHash,
	}, nil
}

func (service *Service) SendRegistrationCode(ctx context.Context, rawEmail, remoteAddress string) error {
	if service.registrationMode != "open" {
		return ErrRegistrationDisabled
	}
	if service.mailer == nil {
		return ErrUnavailable
	}
	email, err := registration.ValidateSendCodeInput(rawEmail)
	if err != nil {
		return err
	}
	now := service.now().UTC()

	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin email code transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "register:"+email); err != nil {
		return fmt.Errorf("lock email code scope: %w", err)
	}
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE email_normalized = $1)`, email).Scan(&exists); err != nil {
		return fmt.Errorf("check registered email: %w", err)
	}
	if exists {
		// Keep the HTTP response indistinguishable from a normal accepted request.
		return tx.Commit(ctx)
	}

	var lastSent *time.Time
	if err := tx.QueryRow(ctx, `SELECT max(sent_at) FROM email_codes WHERE email_normalized = $1 AND purpose = 'REGISTER'`, email).Scan(&lastSent); err != nil {
		return fmt.Errorf("read email code cooldown: %w", err)
	}
	if lastSent != nil && now.Sub(lastSent.UTC()) < registrationCodeCooldown {
		return ErrRateLimited
	}
	var recentCount int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM email_codes WHERE email_normalized = $1 AND purpose = 'REGISTER' AND sent_at >= $2`, email, now.Add(-registrationCodeWindow)).Scan(&recentCount); err != nil {
		return fmt.Errorf("read email code rate: %w", err)
	}
	if recentCount >= registrationCodeMaxBurst {
		return ErrRateLimited
	}

	code, err := service.codec.Generate()
	if err != nil {
		return err
	}
	codeHash := service.codec.Hash(email, emailcode.PurposeRegister, code)
	var requestIPHash []byte
	if host, _, splitErr := net.SplitHostPort(strings.TrimSpace(remoteAddress)); splitErr == nil && host != "" {
		requestIPHash = service.codec.HashMetadata("request-ip", host)
	}
	var codeID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO email_codes (purpose, email_normalized, code_hash, created_at, sent_at, expires_at, request_ip_hash)
		VALUES ('REGISTER', $1, $2, $3, $3, $4, $5)
		RETURNING id
	`, email, codeHash, now, now.Add(registrationCodeTTL), requestIPHash).Scan(&codeID); err != nil {
		return fmt.Errorf("store email verification code: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit email verification code: %w", err)
	}

	if err := service.mailer.SendVerificationCode(ctx, email, string(emailcode.PurposeRegister), code); err != nil {
		_, _ = service.pool.Exec(context.Background(), `UPDATE email_codes SET consumed_at = now() WHERE id = $1 AND consumed_at IS NULL`, codeID)
		return fmt.Errorf("send verification email: %w", err)
	}
	return nil
}

func (service *Service) Register(ctx context.Context, raw registration.RegisterInput) (AuthSession, error) {
	if service.registrationMode != "open" {
		return AuthSession{}, ErrRegistrationDisabled
	}
	input, err := registration.ValidateRegisterInput(raw)
	if err != nil {
		return AuthSession{}, err
	}
	passwordHash, err := service.hasher.Hash(input.Password)
	if err != nil {
		return AuthSession{}, err
	}
	now := service.now().UTC()

	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return AuthSession{}, fmt.Errorf("begin registration transaction: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "register:"+input.Email); err != nil {
		return AuthSession{}, fmt.Errorf("lock registration email: %w", err)
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "handle:"+input.Handle); err != nil {
		return AuthSession{}, fmt.Errorf("lock registration handle: %w", err)
	}

	var codeID uuid.UUID
	var codeHash []byte
	var attempts int
	var maxAttempts int
	var expiresAt time.Time
	err = tx.QueryRow(ctx, `
		SELECT id, code_hash, attempts, max_attempts, expires_at
		FROM email_codes
		WHERE email_normalized = $1 AND purpose = 'REGISTER' AND consumed_at IS NULL
		ORDER BY created_at DESC
		LIMIT 1
		FOR UPDATE
	`, input.Email).Scan(&codeID, &codeHash, &attempts, &maxAttempts, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return AuthSession{}, ErrInvalidCode
	}
	if err != nil {
		return AuthSession{}, fmt.Errorf("load email verification code: %w", err)
	}
	if !expiresAt.After(now) || attempts >= maxAttempts {
		_, _ = tx.Exec(ctx, `UPDATE email_codes SET consumed_at = $2 WHERE id = $1`, codeID, now)
		if commitErr := tx.Commit(ctx); commitErr != nil {
			return AuthSession{}, fmt.Errorf("expire email verification code: %w", commitErr)
		}
		return AuthSession{}, ErrInvalidCode
	}
	if !service.codec.Verify(codeHash, input.Email, emailcode.PurposeRegister, input.Code) {
		attempts++
		if attempts >= maxAttempts {
			_, err = tx.Exec(ctx, `UPDATE email_codes SET attempts = $2, consumed_at = $3 WHERE id = $1`, codeID, attempts, now)
		} else {
			_, err = tx.Exec(ctx, `UPDATE email_codes SET attempts = $2 WHERE id = $1`, codeID, attempts)
		}
		if err != nil {
			return AuthSession{}, fmt.Errorf("record verification attempt: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return AuthSession{}, fmt.Errorf("commit verification attempt: %w", err)
		}
		return AuthSession{}, ErrInvalidCode
	}

	var userID uuid.UUID
	err = tx.QueryRow(ctx, `
		INSERT INTO users (email_normalized, email_verified_at, handle_normalized, display_name, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $2, $2)
		RETURNING id
	`, input.Email, now, input.Handle, input.DisplayName).Scan(&userID)
	if err != nil {
		return AuthSession{}, mapUniqueUserError(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO user_privacy_settings (user_id, updated_at) VALUES ($1, $2)`, userID, now); err != nil {
		return AuthSession{}, fmt.Errorf("create privacy settings: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO auth_passwords (user_id, password_hash, password_changed_at) VALUES ($1, $2, $3)`, userID, passwordHash, now); err != nil {
		return AuthSession{}, fmt.Errorf("store password hash: %w", err)
	}
	var deviceID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO devices (user_id, name, platform, app_version, created_at, last_seen_at)
		VALUES ($1, $2, $3, $4, $5, $5)
		RETURNING id
	`, userID, input.Device.Name, input.Device.Platform, input.Device.AppVersion, now).Scan(&deviceID); err != nil {
		return AuthSession{}, fmt.Errorf("create initial device: %w", err)
	}
	access, refresh, err := service.newTokenPair(userID, deviceID, uuid.Nil)
	if err != nil {
		return AuthSession{}, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO refresh_tokens (user_id, device_id, family_id, token_hash, issued_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6)
	`, userID, deviceID, refresh.FamilyID, refresh.Hash, now, refresh.ExpiresAt); err != nil {
		return AuthSession{}, fmt.Errorf("store refresh token: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE email_codes SET consumed_at = $2 WHERE id = $1`, codeID, now); err != nil {
		return AuthSession{}, fmt.Errorf("consume verification code: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return AuthSession{}, fmt.Errorf("commit registration: %w", err)
	}
	return buildSession(userID, input.Email, input.Handle, input.DisplayName, deviceID, input.Device, access, refresh), nil
}

func (service *Service) Login(ctx context.Context, raw LoginInput) (AuthSession, error) {
	email, err := identity.NormalizeEmail(raw.Email)
	if err != nil {
		return AuthSession{}, ErrInvalidCredentials
	}
	device, err := registration.ValidateDeviceInput(raw.Device)
	if err != nil {
		return AuthSession{}, err
	}
	if raw.Password == "" {
		return AuthSession{}, ErrInvalidCredentials
	}
	allowed, rateErr := service.loginAllowed(ctx, email)
	if rateErr != nil {
		return AuthSession{}, fmt.Errorf("check login rate: %w", rateErr)
	}
	if !allowed {
		service.audit(ctx, uuid.Nil, uuid.Nil, "LOGIN_RATE_LIMITED", fmt.Sprintf(`{"email":%q}`, email))
		return AuthSession{}, ErrLoginRateLimited
	}

	var userID uuid.UUID
	var handle string
	var displayName string
	var passwordHash string
	err = service.pool.QueryRow(ctx, `
		SELECT u.id, u.handle_normalized, u.display_name, p.password_hash
		FROM users u
		JOIN auth_passwords p ON p.user_id = u.id
		WHERE u.email_normalized = $1 AND u.status = 'ACTIVE'
	`, email).Scan(&userID, &handle, &displayName, &passwordHash)
	if errors.Is(err, pgx.ErrNoRows) {
		_, _ = service.hasher.Verify(service.dummyPasswordHash, raw.Password)
		service.recordLoginAttempt(ctx, email, false)
		service.audit(ctx, uuid.Nil, uuid.Nil, "LOGIN_FAILED", fmt.Sprintf(`{"email":%q}`, email))
		return AuthSession{}, ErrInvalidCredentials
	}
	if err != nil {
		return AuthSession{}, fmt.Errorf("load login account: %w", err)
	}
	verified, err := service.hasher.Verify(passwordHash, raw.Password)
	if err != nil || !verified.Match {
		service.recordLoginAttempt(ctx, email, false)
		service.audit(ctx, userID, uuid.Nil, "LOGIN_FAILED", `{}`)
		return AuthSession{}, ErrInvalidCredentials
	}

	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return AuthSession{}, fmt.Errorf("begin login transaction: %w", err)
	}
	defer tx.Rollback(ctx)
	if verified.NeedsRehash {
		rehashed, hashErr := service.hasher.Hash(raw.Password)
		if hashErr != nil {
			return AuthSession{}, hashErr
		}
		if _, err := tx.Exec(ctx, `UPDATE auth_passwords SET password_hash = $2, password_changed_at = $3 WHERE user_id = $1`, userID, rehashed, now); err != nil {
			return AuthSession{}, fmt.Errorf("rehash password: %w", err)
		}
	}
	var deviceID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO devices (user_id, name, platform, app_version, created_at, last_seen_at)
		VALUES ($1, $2, $3, $4, $5, $5)
		RETURNING id
	`, userID, device.Name, device.Platform, device.AppVersion, now).Scan(&deviceID); err != nil {
		return AuthSession{}, fmt.Errorf("create login device: %w", err)
	}
	access, refresh, err := service.newTokenPair(userID, deviceID, uuid.Nil)
	if err != nil {
		return AuthSession{}, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO refresh_tokens (user_id, device_id, family_id, token_hash, issued_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6)
	`, userID, deviceID, refresh.FamilyID, refresh.Hash, now, refresh.ExpiresAt); err != nil {
		return AuthSession{}, fmt.Errorf("store login refresh token: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return AuthSession{}, fmt.Errorf("commit login: %w", err)
	}
	service.recordLoginAttempt(ctx, email, true)
	service.audit(ctx, userID, deviceID, "LOGIN_SUCCEEDED", `{}`)
	return buildSession(userID, email, handle, displayName, deviceID, device, access, refresh), nil
}

func (service *Service) CreateTrustedSessionTx(
	ctx context.Context,
	tx pgx.Tx,
	userID uuid.UUID,
	rawDevice registration.DeviceInput,
) (AuthSession, error) {
	device, err := registration.ValidateDeviceInput(rawDevice)
	if err != nil {
		return AuthSession{}, err
	}
	var email, handle, displayName string
	if err := tx.QueryRow(ctx, `
		SELECT email_normalized,handle_normalized,display_name
		FROM users
		WHERE id=$1 AND status='ACTIVE'
	`, userID).Scan(&email, &handle, &displayName); errors.Is(err, pgx.ErrNoRows) {
		return AuthSession{}, ErrUnauthorized
	} else if err != nil {
		return AuthSession{}, fmt.Errorf("load trusted session user: %w", err)
	}
	now := service.now().UTC()
	var deviceID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO devices(user_id,name,platform,app_version,created_at,last_seen_at)
		VALUES($1,$2,$3,$4,$5,$5)
		RETURNING id
	`, userID, device.Name, device.Platform, device.AppVersion, now).Scan(&deviceID); err != nil {
		return AuthSession{}, fmt.Errorf("create trusted session device: %w", err)
	}
	access, refresh, err := service.newTokenPair(userID, deviceID, uuid.Nil)
	if err != nil {
		return AuthSession{}, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO refresh_tokens(user_id,device_id,family_id,token_hash,issued_at,expires_at)
		VALUES($1,$2,$3,$4,$5,$6)
	`, userID, deviceID, refresh.FamilyID, refresh.Hash, now, refresh.ExpiresAt); err != nil {
		return AuthSession{}, fmt.Errorf("store trusted session refresh token: %w", err)
	}
	return buildSession(userID, email, handle, displayName, deviceID, device, access, refresh), nil
}

func (service *Service) AuditTrustedSession(ctx context.Context, userID, deviceID uuid.UUID, eventType string) {
	service.audit(ctx, userID, deviceID, eventType, `{}`)
}

func (service *Service) Refresh(ctx context.Context, rawRefreshToken string) (AuthSession, error) {
	hash, err := session.HashRefreshToken(strings.TrimSpace(rawRefreshToken))
	if err != nil {
		return AuthSession{}, ErrInvalidRefreshToken
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return AuthSession{}, fmt.Errorf("begin refresh transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	var tokenID uuid.UUID
	var userID uuid.UUID
	var deviceID uuid.UUID
	var familyID uuid.UUID
	var usedAt *time.Time
	var revokedAt *time.Time
	var expiresAt time.Time
	var deviceRevokedAt *time.Time
	var email, handle, displayName, deviceName, platform, appVersion string
	err = tx.QueryRow(ctx, `
		SELECT rt.id, rt.user_id, rt.device_id, rt.family_id, rt.used_at, rt.revoked_at, rt.expires_at,
		       u.email_normalized, u.handle_normalized, u.display_name,
		       d.name, d.platform, d.app_version, d.revoked_at
		FROM refresh_tokens rt
		JOIN users u ON u.id = rt.user_id AND u.status = 'ACTIVE'
		JOIN devices d ON d.id = rt.device_id
		WHERE rt.token_hash = $1
		FOR UPDATE OF rt
	`, hash).Scan(&tokenID, &userID, &deviceID, &familyID, &usedAt, &revokedAt, &expiresAt, &email, &handle, &displayName, &deviceName, &platform, &appVersion, &deviceRevokedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return AuthSession{}, ErrInvalidRefreshToken
	}
	if err != nil {
		return AuthSession{}, fmt.Errorf("load refresh token: %w", err)
	}
	if deviceRevokedAt != nil {
		return AuthSession{}, ErrDeviceSessionRevoked
	}
	if usedAt != nil {
		if _, err := tx.Exec(ctx, `
			UPDATE refresh_tokens
			SET revoked_at = COALESCE(revoked_at, $2), revoke_reason = COALESCE(revoke_reason, 'REUSE_DETECTED')
			WHERE family_id = $1
		`, familyID, now); err != nil {
			return AuthSession{}, fmt.Errorf("revoke reused refresh family: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return AuthSession{}, fmt.Errorf("commit refresh family revocation: %w", err)
		}
		return AuthSession{}, ErrRefreshReuse
	}
	if revokedAt != nil || !expiresAt.After(now) {
		return AuthSession{}, ErrInvalidRefreshToken
	}

	access, refresh, err := service.newTokenPair(userID, deviceID, familyID)
	if err != nil {
		return AuthSession{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET used_at = $2 WHERE id = $1 AND used_at IS NULL`, tokenID, now); err != nil {
		return AuthSession{}, fmt.Errorf("consume refresh token: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO refresh_tokens (user_id, device_id, family_id, parent_token_id, token_hash, issued_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
	`, userID, deviceID, familyID, tokenID, refresh.Hash, now, refresh.ExpiresAt); err != nil {
		return AuthSession{}, fmt.Errorf("store rotated refresh token: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE devices SET last_seen_at = $2 WHERE id = $1`, deviceID, now); err != nil {
		return AuthSession{}, fmt.Errorf("update device activity: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return AuthSession{}, fmt.Errorf("commit refresh rotation: %w", err)
	}
	device := registration.DeviceInput{Name: deviceName, Platform: platform, AppVersion: appVersion}
	return buildSession(userID, email, handle, displayName, deviceID, device, access, refresh), nil
}

func (service *Service) newTokenPair(userID, deviceID, familyID uuid.UUID) (session.AccessToken, session.RefreshToken, error) {
	access, err := service.sessions.NewAccessToken(userID, deviceID)
	if err != nil {
		return session.AccessToken{}, session.RefreshToken{}, err
	}
	refresh, err := service.sessions.NewRefreshToken(familyID)
	if err != nil {
		return session.AccessToken{}, session.RefreshToken{}, err
	}
	return access, refresh, nil
}

func buildSession(userID uuid.UUID, email, handle, displayName string, deviceID uuid.UUID, device registration.DeviceInput, access session.AccessToken, refresh session.RefreshToken) AuthSession {
	return AuthSession{
		User:   User{ID: userID.String(), Email: email, Handle: handle, DisplayName: displayName},
		Device: Device{ID: deviceID.String(), Name: device.Name, Platform: device.Platform, AppVersion: device.AppVersion},
		Tokens: Tokens{
			AccessToken: access.Raw, AccessExpiresAt: access.ExpiresAt,
			RefreshToken: refresh.Raw, RefreshExpiresAt: refresh.ExpiresAt,
		},
	}
}

func mapUniqueUserError(err error) error {
	var pgError *pgconn.PgError
	if !errors.As(err, &pgError) || pgError.Code != "23505" {
		return fmt.Errorf("create user: %w", err)
	}
	switch pgError.ConstraintName {
	case "users_email_normalized_key":
		return ErrEmailExists
	case "users_handle_normalized_key":
		return ErrHandleExists
	default:
		return fmt.Errorf("create user: %w", err)
	}
}
