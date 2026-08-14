package admin

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

type Role string

const (
	RoleSuperAdmin      Role = "SUPER_ADMIN"
	RoleModerator       Role = "MODERATOR"
	RoleSupportReadOnly Role = "SUPPORT_READ_ONLY"
)

func (role Role) Valid() bool {
	switch role {
	case RoleSuperAdmin, RoleModerator, RoleSupportReadOnly:
		return true
	default:
		return false
	}
}

func (role Role) CanTriageReports() bool {
	return role == RoleSuperAdmin || role == RoleModerator
}

func (role Role) CanModerateUsers() bool {
	return role == RoleSuperAdmin
}

func (role Role) CanReadAudit() bool {
	return role == RoleSuperAdmin || role == RoleSupportReadOnly
}

func (role Role) CanManageIntegrations() bool {
	return role == RoleSuperAdmin
}

func (role Role) CanManageAdmins() bool {
	return role == RoleSuperAdmin
}

var (
	ErrUnavailable        = errors.New("admin service unavailable")
	ErrInvalidCredentials = errors.New("invalid admin credentials")
	ErrRateLimited        = errors.New("admin login rate limited")
	ErrReportRateLimited  = errors.New("report creation rate limited")
	ErrInvalidMFA         = errors.New("invalid mfa code")
	ErrChallengeExpired   = errors.New("admin authentication challenge expired")
	ErrUnauthorized       = errors.New("admin session unauthorized")
	ErrForbidden          = errors.New("admin operation forbidden")
	ErrNotFound           = errors.New("admin resource not found")
	ErrConflict           = errors.New("admin resource conflict")
	ErrInvalidInput       = errors.New("invalid admin input")
)

type ClientContext struct {
	RemoteAddress string
	UserAgent     string
}

type Identity struct {
	ID    string `json:"id"`
	Email string `json:"email"`
	Role  Role   `json:"role"`
}

type AdminAccountSummary struct {
	ID             string     `json:"id"`
	Email          string     `json:"email"`
	Role           Role       `json:"role"`
	Status         string     `json:"status"`
	MFAEnabled     bool       `json:"mfaEnabled"`
	CreatedAt      time.Time  `json:"createdAt"`
	UpdatedAt      time.Time  `json:"updatedAt"`
	LastLoginAt    *time.Time `json:"lastLoginAt,omitempty"`
	ActiveSessions int64      `json:"activeSessions"`
}

type Principal struct {
	AdminID   uuid.UUID
	SessionID uuid.UUID
	Email     string
	Role      Role
	ExpiresAt time.Time
}

type LoginResult struct {
	ChallengeToken     string    `json:"challengeToken"`
	ChallengeExpiresAt time.Time `json:"challengeExpiresAt"`
	MFARequired        bool      `json:"mfaRequired"`
	EnrollmentRequired bool      `json:"enrollmentRequired"`
}

type Enrollment struct {
	Secret     string `json:"secret"`
	OTPAuthURI string `json:"otpauthUri"`
}

type SessionResult struct {
	Admin         Identity  `json:"admin"`
	SessionID     string    `json:"sessionId"`
	ExpiresAt     time.Time `json:"expiresAt"`
	IdleExpiresAt time.Time `json:"idleExpiresAt"`
	CSRFToken     string    `json:"csrfToken"`
}

type IssuedSession struct {
	SessionResult
	Token string `json:"-"`
}

type SessionInfo struct {
	ID            string     `json:"id"`
	CreatedAt     time.Time  `json:"createdAt"`
	LastSeenAt    time.Time  `json:"lastSeenAt"`
	IdleExpiresAt time.Time  `json:"idleExpiresAt"`
	ExpiresAt     time.Time  `json:"expiresAt"`
	RevokedAt     *time.Time `json:"revokedAt,omitempty"`
	ClientIP      string     `json:"clientIp,omitempty"`
	UserAgent     string     `json:"userAgent"`
	Current       bool       `json:"current"`
}

type ReportCategory string

type ReportStatus string

const (
	ReportCategorySpam          ReportCategory = "SPAM"
	ReportCategoryHarassment    ReportCategory = "HARASSMENT"
	ReportCategoryImpersonation ReportCategory = "IMPERSONATION"
	ReportCategoryScam          ReportCategory = "SCAM"
	ReportCategoryOther         ReportCategory = "OTHER"

	ReportStatusPending   ReportStatus = "PENDING"
	ReportStatusInReview  ReportStatus = "IN_REVIEW"
	ReportStatusResolved  ReportStatus = "RESOLVED"
	ReportStatusDismissed ReportStatus = "DISMISSED"
)

type CreateReportInput struct {
	TargetUserID string         `json:"targetUserId"`
	Category     ReportCategory `json:"category"`
	Reason       string         `json:"reason"`
}

type UpdateReportInput struct {
	Status ReportStatus `json:"status"`
	Reason string       `json:"reason"`
}

type Report struct {
	ID               string         `json:"id"`
	ReporterUserID   string         `json:"reporterUserId"`
	ReporterHandle   string         `json:"reporterHandle,omitempty"`
	TargetUserID     string         `json:"targetUserId"`
	TargetHandle     string         `json:"targetHandle,omitempty"`
	Category         ReportCategory `json:"category"`
	Reason           string         `json:"reason"`
	Status           ReportStatus   `json:"status"`
	AssignedAdminID  string         `json:"assignedAdminId,omitempty"`
	ResolutionReason string         `json:"resolutionReason,omitempty"`
	CreatedAt        time.Time      `json:"createdAt"`
	UpdatedAt        time.Time      `json:"updatedAt"`
	ResolvedAt       *time.Time     `json:"resolvedAt,omitempty"`
}

type UserSummary struct {
	ID          string    `json:"id"`
	Email       string    `json:"email"`
	Handle      string    `json:"handle"`
	DisplayName string    `json:"displayName"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

type ModerationAction struct {
	ID             string    `json:"id"`
	TargetUserID   string    `json:"targetUserId"`
	ActorAdminID   string    `json:"actorAdminId"`
	Action         string    `json:"action"`
	Reason         string    `json:"reason"`
	PreviousStatus string    `json:"previousStatus"`
	NewStatus      string    `json:"newStatus"`
	CreatedAt      time.Time `json:"createdAt"`
}

type IntegrationSecret struct {
	Key       string
	Value     string
	UpdatedAt time.Time
}

type IntegrationSecretStatus struct {
	Key        string    `json:"key"`
	Configured bool      `json:"configured"`
	UpdatedAt  time.Time `json:"updatedAt,omitempty"`
}

type AuditFilter struct {
	Action       string
	TargetType   string
	ActorAdminID string
	Limit        int
}

type AuditEvent struct {
	ID           string         `json:"id"`
	ActorAdminID string         `json:"actorAdminId,omitempty"`
	SessionID    string         `json:"sessionId,omitempty"`
	ActorRole    Role           `json:"actorRole,omitempty"`
	Action       string         `json:"action"`
	TargetType   string         `json:"targetType,omitempty"`
	TargetID     string         `json:"targetId,omitempty"`
	Reason       string         `json:"reason,omitempty"`
	Detail       map[string]any `json:"detail"`
	ClientIP     string         `json:"clientIp,omitempty"`
	UserAgent    string         `json:"userAgent"`
	CreatedAt    time.Time      `json:"createdAt"`
}
