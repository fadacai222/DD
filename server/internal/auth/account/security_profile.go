package account

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/auth/emailcode"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/identity"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const (
	loginFailureWindow = 15 * time.Minute
	loginFailureLimit  = 10
)

var (
	ErrLoginRateLimited = errors.New("login rate limited")
	ErrUnauthorized     = errors.New("unauthorized")
	ErrForbidden        = errors.New("forbidden")
	ErrNotFound         = errors.New("not found")
)

type Principal struct {
	UserID   uuid.UUID
	DeviceID uuid.UUID
}

type Profile struct {
	ID          string `json:"id"`
	Email       string `json:"email"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
	Bio         string `json:"bio"`
}

type PrivacySettings struct {
	AllowEmailSearch           bool `json:"allowEmailSearch"`
	AllowStrangerMessages      bool `json:"allowStrangerMessages"`
	ShowOnlineStatus           bool `json:"showOnlineStatus"`
	ReadReceiptsEnabled        bool `json:"readReceiptsEnabled"`
	NotificationPreviewEnabled bool `json:"notificationPreviewEnabled"`
}

type Me struct {
	Profile Profile         `json:"profile"`
	Privacy PrivacySettings `json:"privacy"`
}

type UpdateMeInput struct {
	Handle      string          `json:"handle"`
	DisplayName string          `json:"displayName"`
	Bio         string          `json:"bio"`
	Privacy     PrivacySettings `json:"privacy"`
}

type ChangeEmailInput struct {
	Email string `json:"email"`
	Code  string `json:"code"`
}

type ManagedDevice struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Platform   string     `json:"platform"`
	AppVersion string     `json:"appVersion"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastSeenAt time.Time  `json:"lastSeenAt"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
	Current    bool       `json:"current"`
}

type ResetPasswordInput struct {
	Email       string `json:"email"`
	Code        string `json:"code"`
	NewPassword string `json:"newPassword"`
}

func (service *Service) AuthenticateAccessToken(ctx context.Context, raw string) (Principal, error) {
	claims, err := service.sessions.ParseAccessToken(strings.TrimSpace(raw))
	if err != nil {
		return Principal{}, ErrUnauthorized
	}
	userID, _ := uuid.Parse(claims.Subject)
	deviceID, _ := uuid.Parse(claims.DeviceID)
	var active bool
	err = service.pool.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM devices d
			JOIN users u ON u.id = d.user_id
			WHERE d.id = $1 AND d.user_id = $2 AND d.revoked_at IS NULL AND u.status = 'ACTIVE'
		)
	`, deviceID, userID).Scan(&active)
	if err != nil || !active {
		return Principal{}, ErrUnauthorized
	}
	return Principal{UserID: userID, DeviceID: deviceID}, nil
}

func (service *Service) GetMe(ctx context.Context, principal Principal) (Me, error) {
	var result Me
	err := service.pool.QueryRow(ctx, `
		SELECT u.id, u.email_normalized, u.handle_normalized, u.display_name, u.bio,
		       p.allow_email_search, p.allow_stranger_messages, p.show_online_status,
		       p.read_receipts_enabled, p.notification_preview_enabled
		FROM users u JOIN user_privacy_settings p ON p.user_id = u.id
		WHERE u.id = $1 AND u.status = 'ACTIVE'
	`, principal.UserID).Scan(
		&result.Profile.ID, &result.Profile.Email, &result.Profile.Handle,
		&result.Profile.DisplayName, &result.Profile.Bio,
		&result.Privacy.AllowEmailSearch, &result.Privacy.AllowStrangerMessages,
		&result.Privacy.ShowOnlineStatus, &result.Privacy.ReadReceiptsEnabled,
		&result.Privacy.NotificationPreviewEnabled,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Me{}, ErrNotFound
	}
	if err != nil {
		return Me{}, fmt.Errorf("load current user: %w", err)
	}
	return result, nil
}

func (service *Service) UpdateMe(ctx context.Context, principal Principal, input UpdateMeInput) (Me, error) {
	displayName := strings.TrimSpace(input.DisplayName)
	bio := strings.TrimSpace(input.Bio)
	if displayName == "" || utf8.RuneCountInString(displayName) > 80 || utf8.RuneCountInString(bio) > 500 {
		return Me{}, errors.New("invalid profile")
	}
	handle := ""
	if strings.TrimSpace(input.Handle) != "" {
		normalized, err := identity.NormalizeHandle(input.Handle)
		if err != nil {
			return Me{}, fmt.Errorf("invalid handle: %w", err)
		}
		handle = normalized
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return Me{}, fmt.Errorf("begin profile update: %w", err)
	}
	defer tx.Rollback(ctx)
	result, err := tx.Exec(ctx, `
		UPDATE users SET
			display_name = $2,
			bio = $3,
			handle_normalized = CASE WHEN $4 = '' THEN handle_normalized ELSE $4 END,
			updated_at = $5
		WHERE id = $1 AND status = 'ACTIVE'
	`, principal.UserID, displayName, bio, handle, now)
	if err != nil {
		if mapped := mapUniqueUserError(err); errors.Is(mapped, ErrHandleExists) {
			return Me{}, mapped
		}
		return Me{}, fmt.Errorf("update profile: %w", err)
	}
	if result.RowsAffected() != 1 {
		return Me{}, ErrNotFound
	}
	if _, err := tx.Exec(ctx, `
		UPDATE user_privacy_settings SET
			allow_email_search = $2, allow_stranger_messages = $3, show_online_status = $4,
			read_receipts_enabled = $5, notification_preview_enabled = $6, updated_at = $7
		WHERE user_id = $1
	`, principal.UserID, input.Privacy.AllowEmailSearch, input.Privacy.AllowStrangerMessages,
		input.Privacy.ShowOnlineStatus, input.Privacy.ReadReceiptsEnabled,
		input.Privacy.NotificationPreviewEnabled, now); err != nil {
		return Me{}, fmt.Errorf("update privacy: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Me{}, fmt.Errorf("commit profile update: %w", err)
	}
	service.audit(ctx, principal.UserID, principal.DeviceID, "PROFILE_UPDATED", `{}`)
	return service.GetMe(ctx, principal)
}

func (service *Service) ListDevices(ctx context.Context, principal Principal) ([]ManagedDevice, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT id, name, platform, app_version, created_at, last_seen_at, revoked_at
		FROM devices
		WHERE user_id = $1 AND revoked_history_cleared_at IS NULL
		ORDER BY last_seen_at DESC, created_at DESC
	`, principal.UserID)
	if err != nil {
		return nil, fmt.Errorf("list devices: %w", err)
	}
	defer rows.Close()
	devices := make([]ManagedDevice, 0)
	for rows.Next() {
		var d ManagedDevice
		var id uuid.UUID
		if err := rows.Scan(&id, &d.Name, &d.Platform, &d.AppVersion, &d.CreatedAt, &d.LastSeenAt, &d.RevokedAt); err != nil {
			return nil, fmt.Errorf("scan device: %w", err)
		}
		d.ID = id.String()
		d.Current = id == principal.DeviceID
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

func (service *Service) ClearRevokedDevices(ctx context.Context, principal Principal) (int64, error) {
	result, err := service.pool.Exec(ctx, `
		UPDATE devices
		SET revoked_history_cleared_at = $2
		WHERE user_id = $1
		  AND revoked_at IS NOT NULL
		  AND revoked_history_cleared_at IS NULL
	`, principal.UserID, service.now().UTC())
	if err != nil {
		return 0, fmt.Errorf("clear revoked device history: %w", err)
	}
	return result.RowsAffected(), nil
}

func (service *Service) RevokeDevice(ctx context.Context, principal Principal, deviceID uuid.UUID) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin device revoke: %w", err)
	}
	defer tx.Rollback(ctx)
	result, err := tx.Exec(ctx, `UPDATE devices SET revoked_at = COALESCE(revoked_at, $3) WHERE id = $1 AND user_id = $2`, deviceID, principal.UserID, now)
	if err != nil {
		return fmt.Errorf("revoke device: %w", err)
	}
	if result.RowsAffected() != 1 {
		return ErrNotFound
	}
	if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET revoked_at = COALESCE(revoked_at, $2), revoke_reason = COALESCE(revoke_reason, 'DEVICE_REVOKED') WHERE device_id = $1`, deviceID, now); err != nil {
		return fmt.Errorf("revoke device tokens: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit device revoke: %w", err)
	}
	service.audit(ctx, principal.UserID, principal.DeviceID, "DEVICE_REVOKED", fmt.Sprintf(`{"deviceId":%q}`, deviceID.String()))
	return nil
}

func (service *Service) RevokeAllDevices(ctx context.Context, principal Principal) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin all-device revoke: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `UPDATE devices SET revoked_at = COALESCE(revoked_at, $2) WHERE user_id = $1`, principal.UserID, now); err != nil {
		return fmt.Errorf("revoke all devices: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET revoked_at = COALESCE(revoked_at, $2), revoke_reason = COALESCE(revoke_reason, 'LOGOUT_ALL') WHERE user_id = $1`, principal.UserID, now); err != nil {
		return fmt.Errorf("revoke all tokens: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit all-device revoke: %w", err)
	}
	service.audit(ctx, principal.UserID, principal.DeviceID, "LOGOUT_ALL", `{}`)
	return nil
}

func (service *Service) SendEmailChangeCode(ctx context.Context, principal Principal, rawEmail string) error {
	if service.codec == nil || service.mailer == nil {
		return ErrUnavailable
	}
	email, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return fmt.Errorf("invalid email: %w", err)
	}
	var currentEmail string
	if err := service.pool.QueryRow(ctx, `SELECT email_normalized FROM users WHERE id=$1 AND status='ACTIVE'`, principal.UserID).Scan(&currentEmail); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return fmt.Errorf("load current email: %w", err)
	}
	if email == currentEmail {
		return errors.New("new email must be different")
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin email change code: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "change-email:"+email); err != nil {
		return fmt.Errorf("lock email change scope: %w", err)
	}
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE email_normalized=$1 AND status='ACTIVE' AND id<>$2)`, email, principal.UserID).Scan(&exists); err != nil {
		return fmt.Errorf("check email change target: %w", err)
	}
	if exists {
		return ErrEmailExists
	}
	var lastSent *time.Time
	if err := tx.QueryRow(ctx, `SELECT max(sent_at) FROM email_codes WHERE email_normalized=$1 AND purpose='CHANGE_EMAIL'`, email).Scan(&lastSent); err != nil {
		return fmt.Errorf("read email change cooldown: %w", err)
	}
	if lastSent != nil && now.Sub(lastSent.UTC()) < registrationCodeCooldown {
		return ErrRateLimited
	}
	var recent int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM email_codes WHERE email_normalized=$1 AND purpose='CHANGE_EMAIL' AND sent_at >= $2`, email, now.Add(-registrationCodeWindow)).Scan(&recent); err != nil {
		return fmt.Errorf("read email change rate: %w", err)
	}
	if recent >= registrationCodeMaxBurst {
		return ErrRateLimited
	}
	code, err := service.codec.Generate()
	if err != nil {
		return err
	}
	hash := service.codec.Hash(email, emailcode.PurposeChangeEmail, code)
	var codeID uuid.UUID
	if err := tx.QueryRow(ctx, `INSERT INTO email_codes (purpose,email_normalized,code_hash,created_at,sent_at,expires_at) VALUES ('CHANGE_EMAIL',$1,$2,$3,$3,$4) RETURNING id`, email, hash, now, now.Add(registrationCodeTTL)).Scan(&codeID); err != nil {
		return fmt.Errorf("store email change code: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit email change code: %w", err)
	}
	if err := service.mailer.SendVerificationCode(ctx, email, string(emailcode.PurposeChangeEmail), code); err != nil {
		_, _ = service.pool.Exec(context.Background(), `UPDATE email_codes SET consumed_at=now() WHERE id=$1 AND consumed_at IS NULL`, codeID)
		return fmt.Errorf("send email change code: %w", err)
	}
	service.audit(ctx, principal.UserID, principal.DeviceID, "EMAIL_CHANGE_CODE_SENT", `{}`)
	return nil
}

func (service *Service) ChangeEmail(ctx context.Context, principal Principal, raw ChangeEmailInput) (Me, error) {
	email, err := identity.NormalizeEmail(raw.Email)
	if err != nil || strings.TrimSpace(raw.Code) == "" {
		return Me{}, ErrInvalidCode
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Me{}, fmt.Errorf("begin email change: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "change-email-user:"+principal.UserID.String()); err != nil {
		return Me{}, fmt.Errorf("lock email change user: %w", err)
	}
	var codeID uuid.UUID
	var codeHash []byte
	var attempts, maxAttempts int
	var expiresAt time.Time
	err = tx.QueryRow(ctx, `
		SELECT id,code_hash,attempts,max_attempts,expires_at
		FROM email_codes
		WHERE email_normalized=$1 AND purpose='CHANGE_EMAIL' AND consumed_at IS NULL
		ORDER BY created_at DESC LIMIT 1 FOR UPDATE
	`, email).Scan(&codeID, &codeHash, &attempts, &maxAttempts, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Me{}, ErrInvalidCode
	}
	if err != nil {
		return Me{}, fmt.Errorf("load email change code: %w", err)
	}
	if !expiresAt.After(now) || attempts >= maxAttempts || !service.codec.Verify(codeHash, email, emailcode.PurposeChangeEmail, raw.Code) {
		attempts++
		_, _ = tx.Exec(ctx, `UPDATE email_codes SET attempts=LEAST($2,max_attempts), consumed_at=CASE WHEN $2>=max_attempts THEN $3 ELSE consumed_at END WHERE id=$1`, codeID, attempts, now)
		if commitErr := tx.Commit(ctx); commitErr != nil {
			return Me{}, fmt.Errorf("record email change attempt: %w", commitErr)
		}
		return Me{}, ErrInvalidCode
	}
	result, err := tx.Exec(ctx, `UPDATE users SET email_normalized=$2,email_verified_at=$3,updated_at=$3 WHERE id=$1 AND status='ACTIVE'`, principal.UserID, email, now)
	if err != nil {
		if mapped := mapUniqueUserError(err); errors.Is(mapped, ErrEmailExists) {
			return Me{}, mapped
		}
		return Me{}, fmt.Errorf("update email: %w", err)
	}
	if result.RowsAffected() != 1 {
		return Me{}, ErrNotFound
	}
	if _, err := tx.Exec(ctx, `UPDATE email_codes SET consumed_at=$2 WHERE id=$1`, codeID, now); err != nil {
		return Me{}, fmt.Errorf("consume email change code: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Me{}, fmt.Errorf("commit email change: %w", err)
	}
	service.audit(ctx, principal.UserID, principal.DeviceID, "EMAIL_CHANGED", `{}`)
	return service.GetMe(ctx, principal)
}

func (service *Service) SendPasswordResetCode(ctx context.Context, rawEmail string) error {
	if service.codec == nil || service.mailer == nil {
		return ErrUnavailable
	}
	email, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return nil // Enumeration-safe accepted semantics.
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin password reset code: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "reset:"+email); err != nil {
		return fmt.Errorf("lock password reset scope: %w", err)
	}
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE email_normalized=$1 AND status='ACTIVE')`, email).Scan(&exists); err != nil {
		return fmt.Errorf("check password reset account: %w", err)
	}
	if !exists {
		return tx.Commit(ctx)
	}
	var lastSent *time.Time
	if err := tx.QueryRow(ctx, `SELECT max(sent_at) FROM email_codes WHERE email_normalized=$1 AND purpose='PASSWORD_RESET'`, email).Scan(&lastSent); err != nil {
		return fmt.Errorf("read reset cooldown: %w", err)
	}
	if lastSent != nil && now.Sub(lastSent.UTC()) < registrationCodeCooldown {
		return ErrRateLimited
	}
	var recent int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM email_codes WHERE email_normalized=$1 AND purpose='PASSWORD_RESET' AND sent_at >= $2`, email, now.Add(-registrationCodeWindow)).Scan(&recent); err != nil {
		return fmt.Errorf("read reset rate: %w", err)
	}
	if recent >= registrationCodeMaxBurst {
		return ErrRateLimited
	}
	code, err := service.codec.Generate()
	if err != nil {
		return err
	}
	hash := service.codec.Hash(email, emailcode.PurposePasswordReset, code)
	var codeID uuid.UUID
	if err := tx.QueryRow(ctx, `INSERT INTO email_codes (purpose,email_normalized,code_hash,created_at,sent_at,expires_at) VALUES ('PASSWORD_RESET',$1,$2,$3,$3,$4) RETURNING id`, email, hash, now, now.Add(registrationCodeTTL)).Scan(&codeID); err != nil {
		return fmt.Errorf("store reset code: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit reset code: %w", err)
	}
	if err := service.mailer.SendVerificationCode(ctx, email, string(emailcode.PurposePasswordReset), code); err != nil {
		_, _ = service.pool.Exec(context.Background(), `UPDATE email_codes SET consumed_at=now() WHERE id=$1 AND consumed_at IS NULL`, codeID)
		return fmt.Errorf("send reset email: %w", err)
	}
	return nil
}

func (service *Service) ResetPassword(ctx context.Context, raw ResetPasswordInput) error {
	email, err := identity.NormalizeEmail(raw.Email)
	if err != nil || strings.TrimSpace(raw.Code) == "" {
		return ErrInvalidCode
	}
	if err := password.ValidatePolicy(raw.NewPassword); err != nil {
		return err
	}
	newHash, err := service.hasher.Hash(raw.NewPassword)
	if err != nil {
		return err
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return fmt.Errorf("begin password reset: %w", err)
	}
	defer tx.Rollback(ctx)
	var codeID, userID uuid.UUID
	var codeHash []byte
	var attempts, maxAttempts int
	var expiresAt time.Time
	err = tx.QueryRow(ctx, `
		SELECT ec.id, ec.code_hash, ec.attempts, ec.max_attempts, ec.expires_at, u.id
		FROM email_codes ec JOIN users u ON u.email_normalized=ec.email_normalized AND u.status='ACTIVE'
		WHERE ec.email_normalized=$1 AND ec.purpose='PASSWORD_RESET' AND ec.consumed_at IS NULL
		ORDER BY ec.created_at DESC LIMIT 1 FOR UPDATE OF ec
	`, email).Scan(&codeID, &codeHash, &attempts, &maxAttempts, &expiresAt, &userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrInvalidCode
	}
	if err != nil {
		return fmt.Errorf("load password reset code: %w", err)
	}
	if !expiresAt.After(now) || attempts >= maxAttempts || !service.codec.Verify(codeHash, email, emailcode.PurposePasswordReset, raw.Code) {
		attempts++
		_, _ = tx.Exec(ctx, `UPDATE email_codes SET attempts=LEAST($2,max_attempts), consumed_at=CASE WHEN $2>=max_attempts THEN $3 ELSE consumed_at END WHERE id=$1`, codeID, attempts, now)
		if commitErr := tx.Commit(ctx); commitErr != nil {
			return fmt.Errorf("record reset attempt: %w", commitErr)
		}
		return ErrInvalidCode
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_passwords SET password_hash=$2,password_changed_at=$3 WHERE user_id=$1`, userID, newHash, now); err != nil {
		return fmt.Errorf("update reset password: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE email_codes SET consumed_at=$2 WHERE id=$1`, codeID, now); err != nil {
		return fmt.Errorf("consume reset code: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE devices SET revoked_at=COALESCE(revoked_at,$2) WHERE user_id=$1`, userID, now); err != nil {
		return fmt.Errorf("revoke reset devices: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,$2),revoke_reason=COALESCE(revoke_reason,'PASSWORD_RESET') WHERE user_id=$1`, userID, now); err != nil {
		return fmt.Errorf("revoke reset tokens: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit password reset: %w", err)
	}
	service.audit(ctx, userID, uuid.Nil, "PASSWORD_RESET", `{}`)
	return nil
}

func (service *Service) loginAllowed(ctx context.Context, email string) (bool, error) {
	var failures int
	err := service.pool.QueryRow(ctx, `SELECT count(*) FROM auth_login_attempts WHERE email_normalized=$1 AND succeeded=false AND attempted_at >= $2`, email, service.now().UTC().Add(-loginFailureWindow)).Scan(&failures)
	return failures < loginFailureLimit, err
}

func (service *Service) recordLoginAttempt(ctx context.Context, email string, succeeded bool) {
	_, _ = service.pool.Exec(ctx, `INSERT INTO auth_login_attempts (email_normalized,succeeded,attempted_at) VALUES ($1,$2,$3)`, email, succeeded, service.now().UTC())
}

func (service *Service) audit(ctx context.Context, userID, deviceID uuid.UUID, eventType, detail string) {
	var u any
	var d any
	if userID != uuid.Nil {
		u = userID
	}
	if deviceID != uuid.Nil {
		d = deviceID
	}
	_, _ = service.pool.Exec(ctx, `INSERT INTO auth_audit_events (user_id,device_id,event_type,detail,created_at) VALUES ($1,$2,$3,$4::jsonb,$5)`, u, d, eventType, detail, service.now().UTC())
}
