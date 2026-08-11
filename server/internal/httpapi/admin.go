package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/admin"
	"github.com/google/uuid"
)

const adminSessionCookie = "dd_admin_session"

type AdminService interface {
	Login(ctx context.Context, email, password string, client admin.ClientContext) (admin.LoginResult, error)
	BeginMFAEnrollment(ctx context.Context, challengeToken string) (admin.Enrollment, error)
	VerifyMFAEnrollment(ctx context.Context, challengeToken, code string, client admin.ClientContext) (admin.IssuedSession, []string, error)
	VerifyMFA(ctx context.Context, challengeToken, code, recoveryCode string, client admin.ClientContext) (admin.IssuedSession, error)
	AuthenticateSession(ctx context.Context, rawToken string) (admin.Principal, admin.SessionResult, error)
	VerifyCSRF(rawSessionToken, provided string) bool
	ListSessions(ctx context.Context, principal admin.Principal) ([]admin.SessionInfo, error)
	RevokeSession(ctx context.Context, principal admin.Principal, sessionID uuid.UUID, reason string, client admin.ClientContext) error
	RegenerateRecoveryCodes(ctx context.Context, principal admin.Principal, code string, client admin.ClientContext) ([]string, error)
	CreateReport(ctx context.Context, reporterUserID uuid.UUID, input admin.CreateReportInput) (admin.Report, error)
	GetOwnReport(ctx context.Context, reporterUserID, reportID uuid.UUID) (admin.Report, error)
	ListReports(ctx context.Context, principal admin.Principal, status admin.ReportStatus, limit int) ([]admin.Report, error)
	GetReport(ctx context.Context, principal admin.Principal, reportID uuid.UUID) (admin.Report, error)
	UpdateReport(ctx context.Context, principal admin.Principal, reportID uuid.UUID, input admin.UpdateReportInput, client admin.ClientContext) (admin.Report, error)
	ListUsers(ctx context.Context, principal admin.Principal, status, query string, limit int) ([]admin.UserSummary, error)
	GetUser(ctx context.Context, principal admin.Principal, userID uuid.UUID) (admin.UserSummary, error)
	ModerateUser(ctx context.Context, principal admin.Principal, userID uuid.UUID, action, reason string, client admin.ClientContext) (admin.UserSummary, admin.ModerationAction, error)
	ListAuditEvents(ctx context.Context, principal admin.Principal, limit int) ([]admin.AuditEvent, error)
}

type adminLoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type adminChallengeRequest struct {
	ChallengeToken string `json:"challengeToken"`
	Code           string `json:"code"`
	RecoveryCode   string `json:"recoveryCode"`
}

type adminReasonRequest struct {
	Reason string `json:"reason"`
}

func (s *server) handleAdminLogin(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAdminService(response) || !requireJSON(response, request) {
		return
	}
	var input adminLoginRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	result, err := s.admin.Login(request.Context(), input.Email, input.Password, adminClientContext(request))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleAdminMFAEnroll(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAdminService(response) || !requireJSON(response, request) {
		return
	}
	var input adminChallengeRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	result, err := s.admin.BeginMFAEnrollment(request.Context(), input.ChallengeToken)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleAdminMFAEnrollVerify(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAdminService(response) || !requireJSON(response, request) {
		return
	}
	var input adminChallengeRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	issued, recoveryCodes, err := s.admin.VerifyMFAEnrollment(request.Context(), input.ChallengeToken, input.Code, adminClientContext(request))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	s.setAdminSessionCookie(response, request, issued.Token, issued.ExpiresAt)
	writeSuccess(response, http.StatusOK, map[string]any{"session": issued.SessionResult, "recoveryCodes": recoveryCodes})
}

func (s *server) handleAdminMFAVerify(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAdminService(response) || !requireJSON(response, request) {
		return
	}
	var input adminChallengeRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	issued, err := s.admin.VerifyMFA(request.Context(), input.ChallengeToken, input.Code, input.RecoveryCode, adminClientContext(request))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	s.setAdminSessionCookie(response, request, issued.Token, issued.ExpiresAt)
	writeSuccess(response, http.StatusOK, issued.SessionResult)
}

func (s *server) handleAdminSession(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	_, session, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	writeSuccess(response, http.StatusOK, session)
}

func (s *server) handleAdminLogout(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, true)
	if !ok {
		return
	}
	if err := s.admin.RevokeSession(request.Context(), principal, principal.SessionID, "LOGOUT", adminClientContext(request)); err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	s.clearAdminSessionCookie(response, request)
	writeSuccess(response, http.StatusOK, map[string]any{"revoked": true})
}

func (s *server) handleAdminSessions(response http.ResponseWriter, request *http.Request) {
	principal, _, _, ok := s.requireAdminPrincipal(response, request, request.Method != http.MethodGet)
	if !ok {
		return
	}
	if request.URL.Path != "/api/v1/admin/sessions" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	items, err := s.admin.ListSessions(request.Context(), principal)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleAdminSessionByID(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodDelete {
		methodNotAllowed(response, http.MethodDelete)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, true)
	if !ok {
		return
	}
	rawID := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/admin/sessions/"), "/")
	sessionID, err := uuid.Parse(rawID)
	if err != nil || strings.Contains(rawID, "/") {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", "sessionId is invalid")
		return
	}
	if err := s.admin.RevokeSession(request.Context(), principal, sessionID, "ADMIN_REVOKED", adminClientContext(request)); err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	if sessionID == principal.SessionID {
		s.clearAdminSessionCookie(response, request)
	}
	writeSuccess(response, http.StatusOK, map[string]any{"revoked": true})
}

func (s *server) handleAdminRecoveryRegenerate(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, true)
	if !ok || !requireJSON(response, request) {
		return
	}
	var input adminChallengeRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	codes, err := s.admin.RegenerateRecoveryCodes(request.Context(), principal, input.Code, adminClientContext(request))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"recoveryCodes": codes})
}

func (s *server) handleReports(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok || !s.requireAdminService(response) {
		return
	}
	if request.URL.Path != "/api/v1/reports" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input admin.CreateReportInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REPORT_REQUEST", err.Error())
		return
	}
	item, err := s.admin.CreateReport(request.Context(), principal.UserID, input)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusCreated, item)
}

func (s *server) handleReportByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok || !s.requireAdminService(response) {
		return
	}
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	rawID := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/reports/"), "/")
	reportID, err := uuid.Parse(rawID)
	if err != nil || strings.Contains(rawID, "/") {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REPORT_REQUEST", "reportId is invalid")
		return
	}
	item, err := s.admin.GetOwnReport(request.Context(), principal.UserID, reportID)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, item)
}

func (s *server) handleAdminReports(response http.ResponseWriter, request *http.Request) {
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	if request.URL.Path != "/api/v1/admin/reports" || request.Method != http.MethodGet {
		if request.URL.Path != "/api/v1/admin/reports" {
			writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		} else {
			methodNotAllowed(response, http.MethodGet)
		}
		return
	}
	items, err := s.admin.ListReports(request.Context(), principal, admin.ReportStatus(request.URL.Query().Get("status")), queryLimit(request, 50))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleAdminReportByID(response http.ResponseWriter, request *http.Request) {
	principal, _, _, ok := s.requireAdminPrincipal(response, request, request.Method != http.MethodGet)
	if !ok {
		return
	}
	rawID := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/admin/reports/"), "/")
	reportID, err := uuid.Parse(rawID)
	if err != nil || strings.Contains(rawID, "/") {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", "reportId is invalid")
		return
	}
	switch request.Method {
	case http.MethodGet:
		item, err := s.admin.GetReport(request.Context(), principal, reportID)
		if err != nil {
			s.writeAdminError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, item)
	case http.MethodPatch:
		if !requireJSON(response, request) {
			return
		}
		var input admin.UpdateReportInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
			return
		}
		item, err := s.admin.UpdateReport(request.Context(), principal, reportID, input, adminClientContext(request))
		if err != nil {
			s.writeAdminError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, item)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPatch)
	}
}

func (s *server) handleAdminUsers(response http.ResponseWriter, request *http.Request) {
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	if request.URL.Path != "/api/v1/admin/users" || request.Method != http.MethodGet {
		if request.URL.Path != "/api/v1/admin/users" {
			writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		} else {
			methodNotAllowed(response, http.MethodGet)
		}
		return
	}
	items, err := s.admin.ListUsers(request.Context(), principal, request.URL.Query().Get("status"), request.URL.Query().Get("q"), queryLimit(request, 50))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleAdminUserByID(response http.ResponseWriter, request *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/admin/users/"), "/"), "/")
	if len(parts) < 1 || len(parts) > 2 {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	userID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", "userId is invalid")
		return
	}
	mutation := len(parts) == 2
	principal, _, _, ok := s.requireAdminPrincipal(response, request, mutation)
	if !ok {
		return
	}
	if !mutation {
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		item, err := s.admin.GetUser(request.Context(), principal, userID)
		if err != nil {
			s.writeAdminError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, item)
		return
	}
	if request.Method != http.MethodPost || (parts[1] != "suspend" && parts[1] != "unsuspend") {
		if parts[1] != "suspend" && parts[1] != "unsuspend" {
			writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		} else {
			methodNotAllowed(response, http.MethodPost)
		}
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input adminReasonRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	item, action, err := s.admin.ModerateUser(request.Context(), principal, userID, strings.ToUpper(parts[1]), input.Reason, adminClientContext(request))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"user": item, "action": action})
}

func (s *server) handleAdminAudit(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	items, err := s.admin.ListAuditEvents(request.Context(), principal, queryLimit(request, 50))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) requireAdminPrincipal(response http.ResponseWriter, request *http.Request, requireCSRF bool) (admin.Principal, admin.SessionResult, string, bool) {
	if !s.requireAdminService(response) {
		return admin.Principal{}, admin.SessionResult{}, "", false
	}
	cookie, err := request.Cookie(adminSessionCookie)
	if err != nil || strings.TrimSpace(cookie.Value) == "" {
		writeAPIError(response, http.StatusUnauthorized, "ADMIN_UNAUTHORIZED", "Valid administrator session is required")
		return admin.Principal{}, admin.SessionResult{}, "", false
	}
	rawToken := strings.TrimSpace(cookie.Value)
	principal, session, err := s.admin.AuthenticateSession(request.Context(), rawToken)
	if err != nil {
		s.clearAdminSessionCookie(response, request)
		s.writeAdminError(response, request, err)
		return admin.Principal{}, admin.SessionResult{}, "", false
	}
	if requireCSRF && !s.admin.VerifyCSRF(rawToken, request.Header.Get("X-DD-Admin-CSRF")) {
		writeAPIError(response, http.StatusForbidden, "ADMIN_CSRF_INVALID", "Administrator CSRF token is invalid")
		return admin.Principal{}, admin.SessionResult{}, "", false
	}
	return principal, session, rawToken, true
}

func (s *server) requireAdminService(response http.ResponseWriter) bool {
	if s.admin == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "ADMIN_SERVICE_UNAVAILABLE", "Administrator service is not configured")
		return false
	}
	return true
}

func (s *server) writeAdminError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, admin.ErrInvalidCredentials):
		writeAPIError(response, http.StatusUnauthorized, "ADMIN_INVALID_CREDENTIALS", "Email or password is incorrect")
	case errors.Is(err, admin.ErrUnauthorized), errors.Is(err, admin.ErrChallengeExpired):
		writeAPIError(response, http.StatusUnauthorized, "ADMIN_SESSION_EXPIRED", "Administrator session or challenge is no longer valid")
	case errors.Is(err, admin.ErrInvalidMFA):
		writeAPIError(response, http.StatusUnauthorized, "ADMIN_MFA_INVALID", "MFA code is invalid or already used")
	case errors.Is(err, admin.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "ADMIN_FORBIDDEN", "Administrator role does not allow this operation")
	case errors.Is(err, admin.ErrRateLimited):
		response.Header().Set("Retry-After", "900")
		writeAPIError(response, http.StatusTooManyRequests, "ADMIN_RATE_LIMITED", "Too many attempts; try again later")
	case errors.Is(err, admin.ErrReportRateLimited):
		response.Header().Set("Retry-After", "3600")
		writeAPIError(response, http.StatusTooManyRequests, "REPORT_RATE_LIMITED", "Too many reports were created recently")
	case errors.Is(err, admin.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
	case errors.Is(err, admin.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
	case errors.Is(err, admin.ErrConflict):
		writeAPIError(response, http.StatusConflict, "ADMIN_CONFLICT", "Requested operation conflicts with current state")
	case errors.Is(err, admin.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "ADMIN_SERVICE_UNAVAILABLE", "Administrator service is not configured")
	default:
		s.logger.Error("admin request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "ADMIN_INTERNAL_ERROR", "Administrator request failed")
	}
}

func (s *server) setAdminSessionCookie(response http.ResponseWriter, request *http.Request, token string, expiresAt time.Time) {
	maxAge := int(expiresAt.Sub(s.now().UTC()).Seconds())
	if maxAge < 1 {
		maxAge = 1
	}
	http.SetCookie(response, &http.Cookie{
		Name: adminSessionCookie, Value: token, Path: "/api/v1/admin", Expires: expiresAt.UTC(), MaxAge: maxAge,
		HttpOnly: true, Secure: request.TLS != nil || strings.HasPrefix(strings.ToLower(s.publicBaseURL), "https://"), SameSite: http.SameSiteStrictMode,
	})
}

func (s *server) clearAdminSessionCookie(response http.ResponseWriter, request *http.Request) {
	http.SetCookie(response, &http.Cookie{
		Name: adminSessionCookie, Value: "", Path: "/api/v1/admin", MaxAge: -1, Expires: time.Unix(1, 0).UTC(),
		HttpOnly: true, Secure: request.TLS != nil || strings.HasPrefix(strings.ToLower(s.publicBaseURL), "https://"), SameSite: http.SameSiteStrictMode,
	})
}

func adminClientContext(request *http.Request) admin.ClientContext {
	return admin.ClientContext{RemoteAddress: request.RemoteAddr, UserAgent: request.UserAgent()}
}

func queryLimit(request *http.Request, fallback int) int {
	value, err := strconv.Atoi(strings.TrimSpace(request.URL.Query().Get("limit")))
	if err != nil || value <= 0 || value > 100 {
		return fallback
	}
	return value
}
