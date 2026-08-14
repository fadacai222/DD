package admin

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const (
	reportCreateWindow = time.Hour
	reportCreateLimit  = 5
)

func (service *Service) CreateReport(ctx context.Context, reporterUserID uuid.UUID, input CreateReportInput) (Report, error) {
	targetUserID, err := uuid.Parse(strings.TrimSpace(input.TargetUserID))
	if err != nil || targetUserID == uuid.Nil || targetUserID == reporterUserID {
		return Report{}, fmt.Errorf("%w: invalid report target", ErrInvalidInput)
	}
	category := ReportCategory(strings.ToUpper(strings.TrimSpace(string(input.Category))))
	if !validReportCategory(category) {
		return Report{}, fmt.Errorf("%w: invalid report category", ErrInvalidInput)
	}
	reason, err := validateReason(input.Reason)
	if err != nil {
		return Report{}, err
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return Report{}, fmt.Errorf("begin user report: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var reporterActive, targetExists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND status='ACTIVE')`, reporterUserID).Scan(&reporterActive); err != nil {
		return Report{}, fmt.Errorf("check report reporter: %w", err)
	}
	if !reporterActive {
		return Report{}, ErrUnauthorized
	}
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND status IN ('ACTIVE','SUSPENDED'))`, targetUserID).Scan(&targetExists); err != nil {
		return Report{}, fmt.Errorf("check report target: %w", err)
	}
	if !targetExists {
		return Report{}, ErrNotFound
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))`, reporterUserID); err != nil {
		return Report{}, fmt.Errorf("lock report rate limit: %w", err)
	}
	var recentCount int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM user_reports WHERE reporter_user_id=$1 AND created_at >= $2`, reporterUserID, now.Add(-reportCreateWindow)).Scan(&recentCount); err != nil {
		return Report{}, fmt.Errorf("check report rate limit: %w", err)
	}
	if recentCount >= reportCreateLimit {
		return Report{}, ErrReportRateLimited
	}
	var reportID uuid.UUID
	err = tx.QueryRow(ctx, `
		INSERT INTO user_reports(reporter_user_id,target_user_id,category,reason,status,created_at,updated_at)
		VALUES($1,$2,$3,$4,'PENDING',$5,$5) RETURNING id
	`, reporterUserID, targetUserID, string(category), reason, now).Scan(&reportID)
	if err != nil {
		if isUniqueViolation(err) {
			return Report{}, ErrConflict
		}
		return Report{}, fmt.Errorf("create user report: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Report{}, fmt.Errorf("commit user report: %w", err)
	}
	return service.GetOwnReport(ctx, reporterUserID, reportID)
}

func (service *Service) GetOwnReport(ctx context.Context, reporterUserID, reportID uuid.UUID) (Report, error) {
	var result Report
	var id, reporterID, targetID uuid.UUID
	err := service.pool.QueryRow(ctx, `
		SELECT r.id,r.reporter_user_id,r.target_user_id,r.category,r.reason,r.status,
		       COALESCE(r.assigned_admin_id::text,''),COALESCE(r.resolution_reason,''),r.created_at,r.updated_at,r.resolved_at
		FROM user_reports r WHERE r.id=$1 AND r.reporter_user_id=$2
	`, reportID, reporterUserID).Scan(&id, &reporterID, &targetID, &result.Category, &result.Reason, &result.Status,
		&result.AssignedAdminID, &result.ResolutionReason, &result.CreatedAt, &result.UpdatedAt, &result.ResolvedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Report{}, ErrNotFound
	}
	if err != nil {
		return Report{}, fmt.Errorf("load own report: %w", err)
	}
	result.ID = id.String()
	result.ReporterUserID = reporterID.String()
	result.TargetUserID = targetID.String()
	return result, nil
}

func (service *Service) ListReports(ctx context.Context, principal Principal, status ReportStatus, limit int) ([]Report, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	statusFilter := strings.ToUpper(strings.TrimSpace(string(status)))
	if statusFilter != "" && !validReportStatus(ReportStatus(statusFilter)) {
		return nil, fmt.Errorf("%w: invalid report status", ErrInvalidInput)
	}
	rows, err := service.pool.Query(ctx, `
		SELECT r.id,r.reporter_user_id,reporter.handle_normalized,r.target_user_id,target.handle_normalized,
		       r.category,r.reason,r.status,COALESCE(r.assigned_admin_id::text,''),COALESCE(r.resolution_reason,''),
		       r.created_at,r.updated_at,r.resolved_at
		FROM user_reports r
		JOIN users reporter ON reporter.id=r.reporter_user_id
		JOIN users target ON target.id=r.target_user_id
		WHERE ($1='' OR r.status=$1)
		ORDER BY CASE WHEN r.status='PENDING' THEN 0 WHEN r.status='IN_REVIEW' THEN 1 ELSE 2 END, r.created_at ASC
		LIMIT $2
	`, statusFilter, limit)
	if err != nil {
		return nil, fmt.Errorf("list admin reports: %w", err)
	}
	defer rows.Close()
	result := make([]Report, 0)
	for rows.Next() {
		var item Report
		var id, reporterID, targetID uuid.UUID
		if err := rows.Scan(&id, &reporterID, &item.ReporterHandle, &targetID, &item.TargetHandle, &item.Category, &item.Reason, &item.Status,
			&item.AssignedAdminID, &item.ResolutionReason, &item.CreatedAt, &item.UpdatedAt, &item.ResolvedAt); err != nil {
			return nil, fmt.Errorf("scan admin report: %w", err)
		}
		item.ID = id.String()
		item.ReporterUserID = reporterID.String()
		item.TargetUserID = targetID.String()
		result = append(result, item)
	}
	return result, rows.Err()
}

func (service *Service) GetReport(ctx context.Context, principal Principal, reportID uuid.UUID) (Report, error) {
	items, err := service.listReportsByID(ctx, reportID)
	if err != nil {
		return Report{}, err
	}
	if len(items) == 0 {
		return Report{}, ErrNotFound
	}
	return items[0], nil
}

func (service *Service) listReportsByID(ctx context.Context, reportID uuid.UUID) ([]Report, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT r.id,r.reporter_user_id,reporter.handle_normalized,r.target_user_id,target.handle_normalized,
		       r.category,r.reason,r.status,COALESCE(r.assigned_admin_id::text,''),COALESCE(r.resolution_reason,''),
		       r.created_at,r.updated_at,r.resolved_at
		FROM user_reports r
		JOIN users reporter ON reporter.id=r.reporter_user_id
		JOIN users target ON target.id=r.target_user_id
		WHERE r.id=$1
	`, reportID)
	if err != nil {
		return nil, fmt.Errorf("load admin report: %w", err)
	}
	defer rows.Close()
	result := make([]Report, 0, 1)
	for rows.Next() {
		var item Report
		var id, reporterID, targetID uuid.UUID
		if err := rows.Scan(&id, &reporterID, &item.ReporterHandle, &targetID, &item.TargetHandle, &item.Category, &item.Reason, &item.Status,
			&item.AssignedAdminID, &item.ResolutionReason, &item.CreatedAt, &item.UpdatedAt, &item.ResolvedAt); err != nil {
			return nil, fmt.Errorf("scan admin report: %w", err)
		}
		item.ID = id.String()
		item.ReporterUserID = reporterID.String()
		item.TargetUserID = targetID.String()
		result = append(result, item)
	}
	return result, rows.Err()
}

func (service *Service) UpdateReport(ctx context.Context, principal Principal, reportID uuid.UUID, input UpdateReportInput, client ClientContext) (Report, error) {
	if !principal.Role.CanTriageReports() {
		service.auditBestEffort(ctx, &principal.AdminID, &principal.SessionID, principal.Role, "REPORT_STATUS_CHANGE_DENIED", "REPORT", reportID.String(), "", map[string]any{"requestedStatus": input.Status}, client)
		return Report{}, ErrForbidden
	}
	status := ReportStatus(strings.ToUpper(strings.TrimSpace(string(input.Status))))
	if !validReportStatus(status) || status == ReportStatusPending {
		return Report{}, fmt.Errorf("%w: invalid report transition", ErrInvalidInput)
	}
	reason, err := validateReason(input.Reason)
	if err != nil {
		return Report{}, err
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return Report{}, fmt.Errorf("begin report update: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var currentStatus ReportStatus
	if err := tx.QueryRow(ctx, `SELECT status FROM user_reports WHERE id=$1 FOR UPDATE`, reportID).Scan(&currentStatus); errors.Is(err, pgx.ErrNoRows) {
		return Report{}, ErrNotFound
	} else if err != nil {
		return Report{}, fmt.Errorf("load report for update: %w", err)
	}
	if !allowedReportTransition(currentStatus, status) {
		return Report{}, ErrConflict
	}
	var resolvedAt any
	var resolutionReason any
	if status == ReportStatusResolved || status == ReportStatusDismissed {
		resolvedAt = now
		resolutionReason = reason
	}
	if _, err := tx.Exec(ctx, `
		UPDATE user_reports SET status=$2,assigned_admin_id=$3,resolution_reason=$4,resolved_at=$5,updated_at=$6 WHERE id=$1
	`, reportID, string(status), principal.AdminID, resolutionReason, resolvedAt, now); err != nil {
		return Report{}, fmt.Errorf("update user report: %w", err)
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "REPORT_STATUS_CHANGED", "REPORT", reportID.String(), reason,
		map[string]any{"from": currentStatus, "to": status}, client, now); err != nil {
		return Report{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Report{}, fmt.Errorf("commit report update: %w", err)
	}
	return service.GetReport(ctx, principal, reportID)
}

func (service *Service) ListUsers(ctx context.Context, principal Principal, status, query string, limit int) ([]UserSummary, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	status = strings.ToUpper(strings.TrimSpace(status))
	if status != "" && status != "ACTIVE" && status != "SUSPENDED" && status != "DELETING" && status != "DELETED" {
		return nil, fmt.Errorf("%w: invalid user status", ErrInvalidInput)
	}
	query = strings.ToLower(strings.TrimSpace(query))
	if len(query) > 100 {
		query = query[:100]
	}
	rows, err := service.pool.Query(ctx, `
		SELECT id,email_normalized,handle_normalized,display_name,status,created_at,updated_at
		FROM users
		WHERE ($1='' OR status=$1)
		  AND ($2='' OR email_normalized ILIKE '%' || $2 || '%' OR handle_normalized ILIKE '%' || $2 || '%' OR display_name ILIKE '%' || $2 || '%')
		ORDER BY created_at DESC LIMIT $3
	`, status, query, limit)
	if err != nil {
		return nil, fmt.Errorf("list governed users: %w", err)
	}
	defer rows.Close()
	result := make([]UserSummary, 0)
	for rows.Next() {
		var item UserSummary
		var id uuid.UUID
		if err := rows.Scan(&id, &item.Email, &item.Handle, &item.DisplayName, &item.Status, &item.CreatedAt, &item.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan governed user: %w", err)
		}
		item.ID = id.String()
		result = append(result, item)
	}
	return result, rows.Err()
}

func (service *Service) GetUser(ctx context.Context, principal Principal, userID uuid.UUID) (UserSummary, error) {
	var item UserSummary
	var id uuid.UUID
	err := service.pool.QueryRow(ctx, `
		SELECT id,email_normalized,handle_normalized,display_name,status,created_at,updated_at FROM users WHERE id=$1
	`, userID).Scan(&id, &item.Email, &item.Handle, &item.DisplayName, &item.Status, &item.CreatedAt, &item.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return UserSummary{}, ErrNotFound
	}
	if err != nil {
		return UserSummary{}, fmt.Errorf("load governed user: %w", err)
	}
	item.ID = id.String()
	return item, nil
}

func (service *Service) ModerateUser(ctx context.Context, principal Principal, userID uuid.UUID, action, rawReason string, client ClientContext) (UserSummary, ModerationAction, error) {
	if !principal.Role.CanModerateUsers() {
		service.auditBestEffort(ctx, &principal.AdminID, &principal.SessionID, principal.Role, "USER_MODERATION_DENIED", "USER", userID.String(), "", map[string]any{"requestedAction": strings.ToUpper(strings.TrimSpace(action))}, client)
		return UserSummary{}, ModerationAction{}, ErrForbidden
	}
	action = strings.ToUpper(strings.TrimSpace(action))
	if action != "SUSPEND" && action != "UNSUSPEND" {
		return UserSummary{}, ModerationAction{}, fmt.Errorf("%w: invalid moderation action", ErrInvalidInput)
	}
	reason, err := validateReason(rawReason)
	if err != nil {
		return UserSummary{}, ModerationAction{}, err
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return UserSummary{}, ModerationAction{}, fmt.Errorf("begin user moderation: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var previousStatus string
	if err := tx.QueryRow(ctx, `SELECT status FROM users WHERE id=$1 FOR UPDATE`, userID).Scan(&previousStatus); errors.Is(err, pgx.ErrNoRows) {
		return UserSummary{}, ModerationAction{}, ErrNotFound
	} else if err != nil {
		return UserSummary{}, ModerationAction{}, fmt.Errorf("load moderation target: %w", err)
	}
	newStatus := "SUSPENDED"
	if action == "SUSPEND" {
		if previousStatus != "ACTIVE" {
			return UserSummary{}, ModerationAction{}, ErrConflict
		}
	} else {
		newStatus = "ACTIVE"
		if previousStatus != "SUSPENDED" {
			return UserSummary{}, ModerationAction{}, ErrConflict
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET status=$2,updated_at=$3 WHERE id=$1`, userID, newStatus, now); err != nil {
		return UserSummary{}, ModerationAction{}, fmt.Errorf("update moderated user: %w", err)
	}
	if action == "SUSPEND" {
		if _, err := tx.Exec(ctx, `UPDATE devices SET revoked_at=COALESCE(revoked_at,$2) WHERE user_id=$1`, userID, now); err != nil {
			return UserSummary{}, ModerationAction{}, fmt.Errorf("revoke suspended user devices: %w", err)
		}
		if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,$2),revoke_reason=COALESCE(revoke_reason,'ADMIN_SUSPENDED') WHERE user_id=$1`, userID, now); err != nil {
			return UserSummary{}, ModerationAction{}, fmt.Errorf("revoke suspended user sessions: %w", err)
		}
	}
	var actionID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO user_moderation_actions(target_user_id,actor_admin_id,action,reason,previous_status,new_status,created_at)
		VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id
	`, userID, principal.AdminID, action, reason, previousStatus, newStatus, now).Scan(&actionID); err != nil {
		return UserSummary{}, ModerationAction{}, fmt.Errorf("record user moderation action: %w", err)
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "USER_"+action, "USER", userID.String(), reason,
		map[string]any{"from": previousStatus, "to": newStatus, "moderationActionId": actionID.String()}, client, now); err != nil {
		return UserSummary{}, ModerationAction{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return UserSummary{}, ModerationAction{}, fmt.Errorf("commit user moderation: %w", err)
	}
	user, err := service.GetUser(ctx, principal, userID)
	if err != nil {
		return UserSummary{}, ModerationAction{}, err
	}
	return user, ModerationAction{
		ID: actionID.String(), TargetUserID: userID.String(), ActorAdminID: principal.AdminID.String(), Action: action,
		Reason: reason, PreviousStatus: previousStatus, NewStatus: newStatus, CreatedAt: now,
	}, nil
}

func (service *Service) ListAuditEvents(ctx context.Context, principal Principal, limit int) ([]AuditEvent, error) {
	return service.ListAuditEventsFiltered(ctx, principal, AuditFilter{Limit: limit})
}

func (service *Service) ListAuditEventsFiltered(ctx context.Context, principal Principal, filter AuditFilter) ([]AuditEvent, error) {
	if !principal.Role.CanReadAudit() {
		return nil, ErrForbidden
	}
	limit := filter.Limit
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	action := strings.ToUpper(strings.TrimSpace(filter.Action))
	targetType := strings.ToUpper(strings.TrimSpace(filter.TargetType))
	actorAdminID := strings.TrimSpace(filter.ActorAdminID)
	if len(action) > 80 || len(targetType) > 40 || len(actorAdminID) > 64 {
		return nil, fmt.Errorf("%w: invalid audit filter", ErrInvalidInput)
	}
	if actorAdminID != "" {
		parsed, err := uuid.Parse(actorAdminID)
		if err != nil || parsed == uuid.Nil {
			return nil, fmt.Errorf("%w: invalid audit actor administrator ID", ErrInvalidInput)
		}
		actorAdminID = parsed.String()
	}
	rows, err := service.pool.Query(ctx, `
		SELECT id::text,COALESCE(actor_admin_id::text,''),COALESCE(session_id::text,''),COALESCE(actor_role,''),action,
		       COALESCE(target_type,''),COALESCE(target_id,''),COALESCE(reason,''),detail,
		       COALESCE(client_ip::text,''),user_agent,created_at
		FROM admin_audit_events
		WHERE ($1='' OR action ILIKE '%' || $1 || '%')
		  AND ($2='' OR target_type=$2)
		  AND ($3='' OR actor_admin_id::text=$3)
		ORDER BY created_at DESC LIMIT $4
	`, action, targetType, actorAdminID, limit)
	if err != nil {
		return nil, fmt.Errorf("list admin audit events: %w", err)
	}
	defer rows.Close()
	result := make([]AuditEvent, 0)
	for rows.Next() {
		var item AuditEvent
		if err := rows.Scan(&item.ID, &item.ActorAdminID, &item.SessionID, &item.ActorRole, &item.Action, &item.TargetType, &item.TargetID,
			&item.Reason, &item.Detail, &item.ClientIP, &item.UserAgent, &item.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan admin audit event: %w", err)
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func validReportCategory(category ReportCategory) bool {
	switch category {
	case ReportCategorySpam, ReportCategoryHarassment, ReportCategoryImpersonation, ReportCategoryScam, ReportCategoryOther:
		return true
	default:
		return false
	}
}

func validReportStatus(status ReportStatus) bool {
	switch status {
	case ReportStatusPending, ReportStatusInReview, ReportStatusResolved, ReportStatusDismissed:
		return true
	default:
		return false
	}
}

func allowedReportTransition(from, to ReportStatus) bool {
	if from == to {
		return false
	}
	switch from {
	case ReportStatusPending:
		return to == ReportStatusInReview || to == ReportStatusResolved || to == ReportStatusDismissed
	case ReportStatusInReview:
		return to == ReportStatusResolved || to == ReportStatusDismissed
	default:
		return false
	}
}

func validateReason(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	length := utf8.RuneCountInString(value)
	if length < 3 || length > 1000 {
		return "", fmt.Errorf("%w: reason must contain 3-1000 characters", ErrInvalidInput)
	}
	return value, nil
}
