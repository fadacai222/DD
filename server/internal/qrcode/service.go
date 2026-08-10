package qrcode

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/registration"
	"example.com/selfhosted-im/server/internal/groups"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	defaultLoginTTL       = 2 * time.Minute
	defaultGroupInviteTTL = 24 * time.Hour
	maximumGroupInviteTTL = 30 * 24 * time.Hour
	maximumGroupInviteUse = 10000
)

type TrustedSessionIssuer interface {
	CreateTrustedSessionTx(context.Context, pgx.Tx, uuid.UUID, registration.DeviceInput) (account.AuthSession, error)
	AuditTrustedSession(context.Context, uuid.UUID, uuid.UUID, string)
}

type GroupGateway interface {
	RedeemQRInviteTx(context.Context, pgx.Tx, account.Principal, uuid.UUID, uuid.UUID) (bool, error)
	Get(context.Context, account.Principal, uuid.UUID) (groups.Group, error)
	ActiveMemberIDs(context.Context, uuid.UUID) ([]uuid.UUID, error)
}

type Config struct {
	Pool          *pgxpool.Pool
	PublicBaseURL string
	Now           func() time.Time
	Auth          TrustedSessionIssuer
	Groups        GroupGateway
}

type Service struct {
	pool          *pgxpool.Pool
	publicBaseURL string
	now           func() time.Time
	auth          TrustedSessionIssuer
	groups        GroupGateway
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil || config.Auth == nil || config.Groups == nil {
		return nil, ErrUnavailable
	}
	origin, err := normalizeOrigin(config.PublicBaseURL)
	if err != nil {
		return nil, fmt.Errorf("qr public base url: %w", err)
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Service{
		pool:          config.Pool,
		publicBaseURL: origin,
		now:           now,
		auth:          config.Auth,
		groups:        config.Groups,
	}, nil
}

func (service *Service) UserPayload(userID uuid.UUID) (Payload, error) {
	if userID == uuid.Nil {
		return Payload{}, ErrInvalid
	}
	value := buildPayload("user", service.publicBaseURL, "userId", userID.String())
	return Payload{Type: "USER", Value: value}, nil
}

func (service *Service) CreateGroupInvite(
	ctx context.Context,
	principal account.Principal,
	groupID uuid.UUID,
	input CreateGroupInviteInput,
) (GroupInvite, error) {
	if principal.UserID == uuid.Nil || groupID == uuid.Nil {
		return GroupInvite{}, ErrInvalid
	}
	ttl := defaultGroupInviteTTL
	if input.ExpiresInSeconds != 0 {
		ttl = time.Duration(input.ExpiresInSeconds) * time.Second
	}
	if ttl < time.Minute || ttl > maximumGroupInviteTTL {
		return GroupInvite{}, ErrInvalid
	}
	if input.MaxUses != nil && (*input.MaxUses <= 0 || *input.MaxUses > maximumGroupInviteUse) {
		return GroupInvite{}, ErrInvalid
	}
	nonce, nonceHash, err := newNonce()
	if err != nil {
		return GroupInvite{}, err
	}
	now := service.now().UTC()
	expiresAt := now.Add(ttl)
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return GroupInvite{}, fmt.Errorf("begin create group qr invite: %w", err)
	}
	defer tx.Rollback(ctx)
	var role string
	if err := tx.QueryRow(ctx, `
		SELECT cm.role
		FROM conversation_members cm
		JOIN groups g ON g.conversation_id=cm.conversation_id AND g.status='ACTIVE'
		WHERE cm.conversation_id=$1 AND cm.user_id=$2 AND cm.status='ACTIVE'
		FOR SHARE OF cm,g
	`, groupID, principal.UserID).Scan(&role); errors.Is(err, pgx.ErrNoRows) {
		return GroupInvite{}, ErrNotFound
	} else if err != nil {
		return GroupInvite{}, fmt.Errorf("authorize group qr invite: %w", err)
	}
	if role != "OWNER" && role != "ADMIN" {
		return GroupInvite{}, ErrForbidden
	}
	var inviteID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO group_qr_invites(group_id,created_by_user_id,nonce_hash,created_at,expires_at,max_uses)
		VALUES($1,$2,$3,$4,$5,$6)
		RETURNING id
	`, groupID, principal.UserID, nonceHash[:], now, expiresAt, input.MaxUses).Scan(&inviteID); err != nil {
		return GroupInvite{}, fmt.Errorf("insert group qr invite: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return GroupInvite{}, fmt.Errorf("commit group qr invite: %w", err)
	}
	payload := buildPayload("group", service.publicBaseURL, "nonce", nonce)
	return GroupInvite{
		ID: inviteID.String(), GroupID: groupID.String(), Payload: payload,
		CreatedAt: now, ExpiresAt: expiresAt, MaxUses: input.MaxUses,
	}, nil
}

func (service *Service) RevokeGroupInvite(
	ctx context.Context,
	principal account.Principal,
	inviteID uuid.UUID,
) error {
	if principal.UserID == uuid.Nil || inviteID == uuid.Nil {
		return ErrInvalid
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return fmt.Errorf("begin revoke group qr invite: %w", err)
	}
	defer tx.Rollback(ctx)
	var groupID uuid.UUID
	var role string
	if err := tx.QueryRow(ctx, `
		SELECT invite.group_id,cm.role
		FROM group_qr_invites invite
		JOIN conversation_members cm ON cm.conversation_id=invite.group_id AND cm.user_id=$2 AND cm.status='ACTIVE'
		JOIN groups g ON g.conversation_id=invite.group_id AND g.status='ACTIVE'
		WHERE invite.id=$1
		FOR UPDATE OF invite
	`, inviteID, principal.UserID).Scan(&groupID, &role); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return fmt.Errorf("load group qr invite for revoke: %w", err)
	}
	if role != "OWNER" && role != "ADMIN" {
		return ErrForbidden
	}
	if _, err := tx.Exec(ctx, `UPDATE group_qr_invites SET revoked_at=COALESCE(revoked_at,$2) WHERE id=$1`, inviteID, now); err != nil {
		return fmt.Errorf("revoke group qr invite: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit revoke group qr invite: %w", err)
	}
	_ = groupID
	return nil
}

func (service *Service) RedeemGroupInvite(
	ctx context.Context,
	principal account.Principal,
	rawNonce string,
) (GroupRedeemResult, []uuid.UUID, error) {
	if principal.UserID == uuid.Nil {
		return GroupRedeemResult{}, nil, ErrInvalid
	}
	nonceHash, err := hashNonce(rawNonce)
	if err != nil {
		return GroupRedeemResult{}, nil, ErrNotFound
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return GroupRedeemResult{}, nil, fmt.Errorf("begin redeem group qr: %w", err)
	}
	defer tx.Rollback(ctx)
	var groupID, inviterID uuid.UUID
	var expiresAt time.Time
	var revokedAt *time.Time
	var useCount int
	var maxUses *int
	if err := tx.QueryRow(ctx, `
		SELECT group_id,created_by_user_id,expires_at,revoked_at,use_count,max_uses
		FROM group_qr_invites
		WHERE nonce_hash=$1
		FOR UPDATE
	`, nonceHash[:]).Scan(&groupID, &inviterID, &expiresAt, &revokedAt, &useCount, &maxUses); errors.Is(err, pgx.ErrNoRows) {
		return GroupRedeemResult{}, nil, ErrNotFound
	} else if err != nil {
		return GroupRedeemResult{}, nil, fmt.Errorf("load group qr invite: %w", err)
	}
	if revokedAt != nil || !expiresAt.After(now) {
		return GroupRedeemResult{}, nil, ErrExpired
	}
	if maxUses != nil && useCount >= *maxUses {
		return GroupRedeemResult{}, nil, ErrExpired
	}
	joined, err := service.groups.RedeemQRInviteTx(ctx, tx, principal, groupID, inviterID)
	if err != nil {
		return GroupRedeemResult{}, nil, mapGroupError(err)
	}
	if joined {
		if _, err := tx.Exec(ctx, `UPDATE group_qr_invites SET use_count=use_count+1 WHERE nonce_hash=$1`, nonceHash[:]); err != nil {
			return GroupRedeemResult{}, nil, fmt.Errorf("increment group qr use count: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return GroupRedeemResult{}, nil, fmt.Errorf("commit redeem group qr: %w", err)
	}
	group, err := service.groups.Get(ctx, principal, groupID)
	if err != nil {
		return GroupRedeemResult{}, nil, mapGroupError(err)
	}
	if !joined {
		return GroupRedeemResult{Group: group}, nil, nil
	}
	recipients, err := service.groups.ActiveMemberIDs(ctx, groupID)
	if err != nil {
		return GroupRedeemResult{}, nil, err
	}
	return GroupRedeemResult{Group: group}, recipients, nil
}

func (service *Service) CreateLogin(
	ctx context.Context,
	input CreateLoginInput,
) (LoginSession, error) {
	device, err := registration.ValidateDeviceInput(registration.DeviceInput{
		Name: input.Device.Name, Platform: input.Device.Platform, AppVersion: input.Device.AppVersion,
	})
	if err != nil {
		return LoginSession{}, ErrInvalid
	}
	nonce, nonceHash, err := newNonce()
	if err != nil {
		return LoginSession{}, err
	}
	now := service.now().UTC()
	expiresAt := now.Add(defaultLoginTTL)
	if _, err := service.pool.Exec(ctx, `
		INSERT INTO qr_login_sessions(
			nonce_hash,target_origin,requested_device_name,requested_platform,requested_app_version,created_at,expires_at
		) VALUES($1,$2,$3,$4,$5,$6,$7)
	`, nonceHash[:], service.publicBaseURL, device.Name, device.Platform, device.AppVersion, now, expiresAt); err != nil {
		return LoginSession{}, fmt.Errorf("create qr login: %w", err)
	}
	payload := buildPayload("login", service.publicBaseURL, "nonce", nonce)
	return LoginSession{
		Status: "PENDING", Nonce: nonce, Payload: payload,
		Device: DeviceInput{Name: device.Name, Platform: device.Platform, AppVersion: device.AppVersion},
		ExpiresAt: expiresAt,
	}, nil
}

func (service *Service) PollLogin(ctx context.Context, rawNonce string) (LoginSession, error) {
	nonceHash, err := hashNonce(rawNonce)
	if err != nil {
		return LoginSession{}, ErrNotFound
	}
	return service.loadLoginByHash(ctx, nonceHash, false)
}

func (service *Service) ScanLogin(
	ctx context.Context,
	principal account.Principal,
	rawNonce string,
) (LoginSession, error) {
	if principal.UserID == uuid.Nil || principal.DeviceID == uuid.Nil {
		return LoginSession{}, ErrForbidden
	}
	nonceHash, err := hashNonce(rawNonce)
	if err != nil {
		return LoginSession{}, ErrNotFound
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return LoginSession{}, fmt.Errorf("begin scan qr login: %w", err)
	}
	defer tx.Rollback(ctx)
	state, err := loadLoginRow(ctx, tx, nonceHash, true)
	if err != nil {
		return LoginSession{}, err
	}
	if !state.ExpiresAt.After(now) {
		if err := markLoginExpired(ctx, tx, nonceHash); err != nil {
			return LoginSession{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return LoginSession{}, fmt.Errorf("commit qr login expiry: %w", err)
		}
		return LoginSession{}, ErrExpired
	}
	switch state.Status {
	case "PENDING":
		if _, err := tx.Exec(ctx, `
			UPDATE qr_login_sessions
			SET status='SCANNED',scanned_user_id=$2,scanned_device_id=$3,scanned_at=$4
			WHERE nonce_hash=$1
		`, nonceHash[:], principal.UserID, principal.DeviceID, now); err != nil {
			return LoginSession{}, fmt.Errorf("scan qr login: %w", err)
		}
		state.Status = "SCANNED"
		state.ScannedAt = &now
	case "SCANNED", "CONFIRMED":
		if state.ScannedUserID == nil || state.ScannedDeviceID == nil || *state.ScannedUserID != principal.UserID || *state.ScannedDeviceID != principal.DeviceID {
			return LoginSession{}, ErrConflict
		}
	case "REJECTED":
		return LoginSession{}, ErrRejected
	case "CONSUMED":
		return LoginSession{}, ErrConsumed
	case "EXPIRED":
		return LoginSession{}, ErrExpired
	default:
		return LoginSession{}, ErrConflict
	}
	if err := tx.Commit(ctx); err != nil {
		return LoginSession{}, fmt.Errorf("commit scan qr login: %w", err)
	}
	return loginSessionFromRow(state), nil
}

func (service *Service) ConfirmLogin(
	ctx context.Context,
	principal account.Principal,
	rawNonce string,
	approved bool,
) (LoginSession, error) {
	if principal.UserID == uuid.Nil || principal.DeviceID == uuid.Nil {
		return LoginSession{}, ErrForbidden
	}
	nonceHash, err := hashNonce(rawNonce)
	if err != nil {
		return LoginSession{}, ErrNotFound
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return LoginSession{}, fmt.Errorf("begin confirm qr login: %w", err)
	}
	defer tx.Rollback(ctx)
	state, err := loadLoginRow(ctx, tx, nonceHash, true)
	if err != nil {
		return LoginSession{}, err
	}
	if !state.ExpiresAt.After(now) {
		if err := markLoginExpired(ctx, tx, nonceHash); err != nil {
			return LoginSession{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return LoginSession{}, fmt.Errorf("commit qr login expiry: %w", err)
		}
		return LoginSession{}, ErrExpired
	}
	if state.ScannedUserID == nil || state.ScannedDeviceID == nil || *state.ScannedUserID != principal.UserID || *state.ScannedDeviceID != principal.DeviceID {
		return LoginSession{}, ErrForbidden
	}
	if state.Status == "CONSUMED" {
		return LoginSession{}, ErrConsumed
	}
	if state.Status == "EXPIRED" {
		return LoginSession{}, ErrExpired
	}
	if state.Status == "REJECTED" {
		return LoginSession{}, ErrRejected
	}
	if state.Status != "SCANNED" && state.Status != "CONFIRMED" {
		return LoginSession{}, ErrConflict
	}
	status := "REJECTED"
	if approved {
		status = "CONFIRMED"
	}
	if _, err := tx.Exec(ctx, `
		UPDATE qr_login_sessions SET status=$2,confirmed_at=$3 WHERE nonce_hash=$1
	`, nonceHash[:], status, now); err != nil {
		return LoginSession{}, fmt.Errorf("confirm qr login: %w", err)
	}
	state.Status = status
	state.ConfirmedAt = &now
	if err := tx.Commit(ctx); err != nil {
		return LoginSession{}, fmt.Errorf("commit confirm qr login: %w", err)
	}
	return loginSessionFromRow(state), nil
}

func (service *Service) ConsumeLogin(ctx context.Context, rawNonce string) (ConsumeLoginResult, error) {
	nonceHash, err := hashNonce(rawNonce)
	if err != nil {
		return ConsumeLoginResult{}, ErrNotFound
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return ConsumeLoginResult{}, fmt.Errorf("begin consume qr login: %w", err)
	}
	defer tx.Rollback(ctx)
	state, err := loadLoginRow(ctx, tx, nonceHash, true)
	if err != nil {
		return ConsumeLoginResult{}, err
	}
	if !state.ExpiresAt.After(now) {
		if err := markLoginExpired(ctx, tx, nonceHash); err != nil {
			return ConsumeLoginResult{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return ConsumeLoginResult{}, fmt.Errorf("commit qr login expiry: %w", err)
		}
		return ConsumeLoginResult{}, ErrExpired
	}
	switch state.Status {
	case "PENDING", "SCANNED":
		return ConsumeLoginResult{}, ErrConflict
	case "REJECTED":
		return ConsumeLoginResult{}, ErrRejected
	case "CONSUMED":
		return ConsumeLoginResult{}, ErrConsumed
	case "EXPIRED":
		return ConsumeLoginResult{}, ErrExpired
	case "CONFIRMED":
	default:
		return ConsumeLoginResult{}, ErrConflict
	}
	if state.ScannedUserID == nil {
		return ConsumeLoginResult{}, ErrConflict
	}
	session, err := service.auth.CreateTrustedSessionTx(ctx, tx, *state.ScannedUserID, registration.DeviceInput{
		Name: state.DeviceName, Platform: state.Platform, AppVersion: state.AppVersion,
	})
	if err != nil {
		return ConsumeLoginResult{}, fmt.Errorf("create qr trusted session: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE qr_login_sessions SET status='CONSUMED',consumed_at=$2 WHERE nonce_hash=$1 AND status='CONFIRMED'
	`, nonceHash[:], now); err != nil {
		return ConsumeLoginResult{}, fmt.Errorf("consume qr login row: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return ConsumeLoginResult{}, fmt.Errorf("commit qr login consumption: %w", err)
	}
	deviceID, parseErr := uuid.Parse(session.Device.ID)
	if parseErr == nil {
		service.auth.AuditTrustedSession(ctx, sessionUserID(session), deviceID, "QR_LOGIN_SUCCEEDED")
	}
	return ConsumeLoginResult{Session: session}, nil
}

func (service *Service) loadLoginByHash(ctx context.Context, nonceHash [32]byte, lock bool) (LoginSession, error) {
	if lock {
		return LoginSession{}, errors.New("internal: lock requires transaction")
	}
	state, err := loadLoginRow(ctx, service.pool, nonceHash, false)
	if err != nil {
		return LoginSession{}, err
	}
	now := service.now().UTC()
	if !state.ExpiresAt.After(now) && state.Status != "EXPIRED" && state.Status != "CONSUMED" {
		_, _ = service.pool.Exec(ctx, `
			UPDATE qr_login_sessions SET status='EXPIRED'
			WHERE nonce_hash=$1 AND status IN ('PENDING','SCANNED','CONFIRMED')
		`, nonceHash[:])
		state.Status = "EXPIRED"
	}
	return loginSessionFromRow(state), nil
}

type loginRow struct {
	Status          string
	ExpiresAt       time.Time
	ScannedUserID   *uuid.UUID
	ScannedDeviceID *uuid.UUID
	ScannedAt       *time.Time
	ConfirmedAt     *time.Time
	DeviceName      string
	Platform        string
	AppVersion      string
}

type rowQueryer interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func loadLoginRow(ctx context.Context, queryer rowQueryer, nonceHash [32]byte, lock bool) (loginRow, error) {
	query := `
		SELECT status,expires_at,scanned_user_id,scanned_device_id,scanned_at,confirmed_at,
		       requested_device_name,requested_platform,requested_app_version
		FROM qr_login_sessions WHERE nonce_hash=$1`
	if lock {
		query += " FOR UPDATE"
	}
	var state loginRow
	if err := queryer.QueryRow(ctx, query, nonceHash[:]).Scan(
		&state.Status, &state.ExpiresAt, &state.ScannedUserID, &state.ScannedDeviceID,
		&state.ScannedAt, &state.ConfirmedAt, &state.DeviceName, &state.Platform, &state.AppVersion,
	); errors.Is(err, pgx.ErrNoRows) {
		return loginRow{}, ErrNotFound
	} else if err != nil {
		return loginRow{}, fmt.Errorf("load qr login: %w", err)
	}
	state.ExpiresAt = state.ExpiresAt.UTC()
	return state, nil
}

func loginSessionFromRow(state loginRow) LoginSession {
	return LoginSession{
		Status: state.Status,
		Device: DeviceInput{Name: state.DeviceName, Platform: state.Platform, AppVersion: state.AppVersion},
		ExpiresAt: state.ExpiresAt,
		ScannedAt: utcTimePointer(state.ScannedAt), ConfirmedAt: utcTimePointer(state.ConfirmedAt),
	}
}

func markLoginExpired(ctx context.Context, tx pgx.Tx, nonceHash [32]byte) error {
	if _, err := tx.Exec(ctx, `
		UPDATE qr_login_sessions SET status='EXPIRED'
		WHERE nonce_hash=$1 AND status IN ('PENDING','SCANNED','CONFIRMED')
	`, nonceHash[:]); err != nil {
		return fmt.Errorf("expire qr login: %w", err)
	}
	return nil
}

func newNonce() (string, [32]byte, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", [32]byte{}, fmt.Errorf("generate qr nonce: %w", err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(raw[:])
	return nonce, sha256.Sum256([]byte(nonce)), nil
}

func hashNonce(raw string) ([32]byte, error) {
	nonce := strings.TrimSpace(raw)
	decoded, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil || len(decoded) != 32 || len(nonce) > 64 {
		return [32]byte{}, ErrInvalid
	}
	return sha256.Sum256([]byte(nonce)), nil
}

func buildPayload(kind, origin, key, value string) string {
	query := url.Values{}
	query.Set("instance", origin)
	query.Set(key, value)
	return "dd://qr/v1/" + kind + "?" + query.Encode()
}

func normalizeOrigin(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", ErrInvalid
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return "", ErrInvalid
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return strings.TrimRight(parsed.String(), "/"), nil
}

func mapGroupError(err error) error {
	switch {
	case errors.Is(err, groups.ErrInvalidInput):
		return ErrInvalid
	case errors.Is(err, groups.ErrNotFound):
		return ErrNotFound
	case errors.Is(err, groups.ErrForbidden):
		return ErrForbidden
	case errors.Is(err, groups.ErrConflict), errors.Is(err, groups.ErrAlreadyMember), errors.Is(err, groups.ErrMemberLimit):
		return ErrConflict
	default:
		return err
	}
}

func sessionUserID(session account.AuthSession) uuid.UUID {
	id, _ := uuid.Parse(session.User.ID)
	return id
}

func utcTimePointer(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	utc := value.UTC()
	return &utc
}
