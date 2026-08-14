package admin

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"example.com/selfhosted-im/server/internal/identity"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (service *Service) ListAdminAccounts(ctx context.Context, principal Principal) ([]AdminAccountSummary, error) {
	if !principal.Role.CanManageAdmins() {
		return nil, ErrForbidden
	}
	now := service.now().UTC()
	rows, err := service.pool.Query(ctx, `
		SELECT a.id::text,a.email_normalized,a.role,a.status,(a.totp_enabled_at IS NOT NULL),a.created_at,a.updated_at,a.last_login_at,
		       (SELECT count(*) FROM admin_sessions s WHERE s.admin_id=a.id AND s.revoked_at IS NULL AND s.expires_at>$1 AND s.idle_expires_at>$1)
		FROM admin_accounts a ORDER BY a.created_at,a.id
	`, now)
	if err != nil {
		return nil, fmt.Errorf("list admin accounts: %w", err)
	}
	defer rows.Close()
	items := make([]AdminAccountSummary, 0)
	for rows.Next() {
		var item AdminAccountSummary
		if err := rows.Scan(&item.ID, &item.Email, &item.Role, &item.Status, &item.MFAEnabled, &item.CreatedAt, &item.UpdatedAt, &item.LastLoginAt, &item.ActiveSessions); err != nil {
			return nil, fmt.Errorf("scan admin account: %w", err)
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (service *Service) CreateAdminAccount(ctx context.Context, principal Principal, rawEmail, rawPassword string, role Role, client ClientContext) (AdminAccountSummary, error) {
	if !principal.Role.CanManageAdmins() {
		service.auditBestEffort(ctx, &principal.AdminID, &principal.SessionID, principal.Role, "ADMIN_ACCOUNT_CREATE_DENIED", "ADMIN", "", "", nil, client)
		return AdminAccountSummary{}, ErrForbidden
	}
	email, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return AdminAccountSummary{}, fmt.Errorf("%w: invalid admin email", ErrInvalidInput)
	}
	if !role.Valid() {
		return AdminAccountSummary{}, fmt.Errorf("%w: invalid admin role", ErrInvalidInput)
	}
	if err := validateAdminPassword(rawPassword); err != nil {
		return AdminAccountSummary{}, err
	}
	hash, err := service.hasher.Hash(rawPassword)
	if err != nil {
		return AdminAccountSummary{}, fmt.Errorf("hash admin password: %w", err)
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return AdminAccountSummary{}, fmt.Errorf("begin admin account create: %w", err)
	}
	defer tx.Rollback(ctx)
	var id uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO admin_accounts(email_normalized,password_hash,role,status,created_at,updated_at)
		VALUES($1,$2,$3,'ACTIVE',$4,$4) RETURNING id
	`, email, hash, string(role), now).Scan(&id); err != nil {
		if isUniqueViolation(err) {
			return AdminAccountSummary{}, ErrConflict
		}
		return AdminAccountSummary{}, fmt.Errorf("create admin account: %w", err)
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "ADMIN_ACCOUNT_CREATED", "ADMIN", id.String(), "", map[string]any{"role": role, "email": email}, client, now); err != nil {
		return AdminAccountSummary{}, fmt.Errorf("audit admin account create: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return AdminAccountSummary{}, fmt.Errorf("commit admin account create: %w", err)
	}
	return AdminAccountSummary{ID: id.String(), Email: email, Role: role, Status: "ACTIVE", CreatedAt: now, UpdatedAt: now}, nil
}

func (service *Service) UpdateAdminAccount(ctx context.Context, principal Principal, targetID uuid.UUID, role Role, status, reason string, client ClientContext) (AdminAccountSummary, error) {
	if !principal.Role.CanManageAdmins() {
		return AdminAccountSummary{}, ErrForbidden
	}
	status = strings.ToUpper(strings.TrimSpace(status))
	reason = strings.TrimSpace(reason)
	if !role.Valid() || (status != "ACTIVE" && status != "DISABLED") || len(reason) < 3 || len(reason) > 500 {
		return AdminAccountSummary{}, fmt.Errorf("%w: invalid admin account update", ErrInvalidInput)
	}
	if targetID == principal.AdminID && (role != RoleSuperAdmin || status != "ACTIVE") {
		return AdminAccountSummary{}, fmt.Errorf("%w: cannot disable or demote the current super administrator", ErrConflict)
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return AdminAccountSummary{}, fmt.Errorf("begin admin account update: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `LOCK TABLE admin_accounts IN SHARE ROW EXCLUSIVE MODE`); err != nil {
		return AdminAccountSummary{}, fmt.Errorf("lock admin accounts: %w", err)
	}
	var currentRole Role
	var currentStatus string
	if err := tx.QueryRow(ctx, `SELECT role,status FROM admin_accounts WHERE id=$1`, targetID).Scan(&currentRole, &currentStatus); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return AdminAccountSummary{}, ErrNotFound
		}
		return AdminAccountSummary{}, fmt.Errorf("load admin account for update: %w", err)
	}
	if currentRole == RoleSuperAdmin && currentStatus == "ACTIVE" && (role != RoleSuperAdmin || status != "ACTIVE") {
		var activeSuperAdmins int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM admin_accounts WHERE role='SUPER_ADMIN' AND status='ACTIVE'`).Scan(&activeSuperAdmins); err != nil {
			return AdminAccountSummary{}, fmt.Errorf("count active super administrators: %w", err)
		}
		if activeSuperAdmins <= 1 {
			return AdminAccountSummary{}, fmt.Errorf("%w: cannot remove the last active super administrator", ErrConflict)
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_accounts SET role=$2,status=$3,updated_at=$4 WHERE id=$1`, targetID, string(role), status, now); err != nil {
		return AdminAccountSummary{}, fmt.Errorf("update admin account: %w", err)
	}
	if status == "DISABLED" {
		if _, err := tx.Exec(ctx, `UPDATE admin_sessions SET revoked_at=$2,revoke_reason='ADMIN_DISABLED' WHERE admin_id=$1 AND revoked_at IS NULL`, targetID, now); err != nil {
			return AdminAccountSummary{}, fmt.Errorf("revoke disabled admin sessions: %w", err)
		}
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "ADMIN_ACCOUNT_UPDATED", "ADMIN", targetID.String(), reason,
		map[string]any{"previousRole": currentRole, "newRole": role, "previousStatus": currentStatus, "newStatus": status}, client, now); err != nil {
		return AdminAccountSummary{}, fmt.Errorf("audit admin account update: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return AdminAccountSummary{}, fmt.Errorf("commit admin account update: %w", err)
	}
	return service.getAdminAccountSummary(ctx, targetID)
}

func (service *Service) ResetAdminMFA(ctx context.Context, principal Principal, targetID uuid.UUID, reason string, client ClientContext) error {
	if !principal.Role.CanManageAdmins() {
		return ErrForbidden
	}
	reason = strings.TrimSpace(reason)
	if len(reason) < 3 || len(reason) > 500 {
		return fmt.Errorf("%w: invalid MFA reset reason", ErrInvalidInput)
	}
	if targetID == principal.AdminID {
		return fmt.Errorf("%w: current administrator cannot reset its own MFA from an active session", ErrConflict)
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin admin MFA reset: %w", err)
	}
	defer tx.Rollback(ctx)
	result, err := tx.Exec(ctx, `UPDATE admin_accounts SET totp_secret_ciphertext=NULL,totp_enabled_at=NULL,totp_last_counter=NULL,updated_at=$2 WHERE id=$1 AND status='ACTIVE'`, targetID, now)
	if err != nil {
		return fmt.Errorf("reset admin MFA: %w", err)
	}
	if result.RowsAffected() == 0 {
		return ErrNotFound
	}
	if _, err := tx.Exec(ctx, `DELETE FROM admin_recovery_codes WHERE admin_id=$1`, targetID); err != nil {
		return fmt.Errorf("delete admin recovery codes: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_sessions SET revoked_at=$2,revoke_reason='MFA_RESET' WHERE admin_id=$1 AND revoked_at IS NULL`, targetID, now); err != nil {
		return fmt.Errorf("revoke admin sessions after MFA reset: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_auth_challenges SET consumed_at=$2 WHERE admin_id=$1 AND consumed_at IS NULL`, targetID, now); err != nil {
		return fmt.Errorf("invalidate admin auth challenges: %w", err)
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "ADMIN_MFA_RESET", "ADMIN", targetID.String(), reason, nil, client, now); err != nil {
		return fmt.Errorf("audit admin MFA reset: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit admin MFA reset: %w", err)
	}
	return nil
}

func (service *Service) getAdminAccountSummary(ctx context.Context, id uuid.UUID) (AdminAccountSummary, error) {
	now := service.now().UTC()
	var item AdminAccountSummary
	err := service.pool.QueryRow(ctx, `
		SELECT a.id::text,a.email_normalized,a.role,a.status,(a.totp_enabled_at IS NOT NULL),a.created_at,a.updated_at,a.last_login_at,
		       (SELECT count(*) FROM admin_sessions s WHERE s.admin_id=a.id AND s.revoked_at IS NULL AND s.expires_at>$2 AND s.idle_expires_at>$2)
		FROM admin_accounts a WHERE a.id=$1
	`, id, now).Scan(&item.ID, &item.Email, &item.Role, &item.Status, &item.MFAEnabled, &item.CreatedAt, &item.UpdatedAt, &item.LastLoginAt, &item.ActiveSessions)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return AdminAccountSummary{}, ErrNotFound
		}
		return AdminAccountSummary{}, fmt.Errorf("load admin account summary: %w", err)
	}
	return item, nil
}
