package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/admin"
	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/stickers"
	"github.com/google/uuid"
)

type boundaryUserAuthService struct{ AuthService }

func (*boundaryUserAuthService) AuthenticateAccessToken(context.Context, string) (account.Principal, error) {
	return account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}, nil
}

type boundaryAdminService struct {
	AdminService
	principal      admin.Principal
	session        admin.SessionResult
	csrfOK         bool
	moderate       func(admin.Principal) error
	integrationSet func(admin.Principal, string, string) (admin.IntegrationSecretStatus, error)
}

func (fake *boundaryAdminService) AuthenticateSession(context.Context, string) (admin.Principal, admin.SessionResult, error) {
	if fake.principal.AdminID == uuid.Nil {
		return admin.Principal{}, admin.SessionResult{}, admin.ErrUnauthorized
	}
	return fake.principal, fake.session, nil
}

func (fake *boundaryAdminService) VerifyCSRF(string, string) bool { return fake.csrfOK }

func (fake *boundaryAdminService) SetIntegrationSecret(_ context.Context, principal admin.Principal, key, value string, _ admin.ClientContext) (admin.IntegrationSecretStatus, error) {
	if fake.integrationSet != nil {
		return fake.integrationSet(principal, key, value)
	}
	return admin.IntegrationSecretStatus{}, admin.ErrForbidden
}

func (fake *boundaryAdminService) ModerateUser(_ context.Context, principal admin.Principal, userID uuid.UUID, action, reason string, _ admin.ClientContext) (admin.UserSummary, admin.ModerationAction, error) {
	if fake.moderate != nil {
		if err := fake.moderate(principal); err != nil {
			return admin.UserSummary{}, admin.ModerationAction{}, err
		}
	}
	return admin.UserSummary{ID: userID.String(), Status: "SUSPENDED"}, admin.ModerationAction{Action: action, Reason: reason}, nil
}

func TestAdminAPIRejectsOrdinaryBearerTokenWithoutAdminSession(t *testing.T) {
	fake := &boundaryAdminService{}
	handler := NewHandler(Config{AuthService: &boundaryUserAuthService{}, AdminService: fake})
	targetID := uuid.NewString()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/admin/users/"+targetID+"/suspend", strings.NewReader(`{"reason":"confirmed abuse"}`))
	request.Header.Set("Authorization", "Bearer ordinary-dd-user-access-token")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-DD-Admin-CSRF", "forged")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("ordinary bearer admin status=%d body=%s", response.Code, response.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	errorBody, _ := body["error"].(map[string]any)
	if errorBody["code"] != "ADMIN_UNAUTHORIZED" {
		t.Fatalf("ordinary bearer error=%v", errorBody)
	}
}

func TestAdminAPIRequiresCSRFForMutationAndPreservesRBAC(t *testing.T) {
	principal := admin.Principal{AdminID: uuid.New(), SessionID: uuid.New(), Email: "mod@example.test", Role: admin.RoleModerator, ExpiresAt: time.Now().Add(time.Hour)}
	fake := &boundaryAdminService{
		principal: principal,
		session:   admin.SessionResult{Admin: admin.Identity{ID: principal.AdminID.String(), Email: principal.Email, Role: principal.Role}, SessionID: principal.SessionID.String()},
		csrfOK:    false,
		moderate: func(got admin.Principal) error {
			if got.Role != admin.RoleModerator {
				t.Fatalf("principal role=%s", got.Role)
			}
			return admin.ErrForbidden
		},
	}
	handler := NewHandler(Config{AdminService: fake})
	path := "/api/v1/admin/users/" + uuid.NewString() + "/suspend"

	withoutCSRF := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{"reason":"confirmed abuse"}`))
	withoutCSRF.AddCookie(&http.Cookie{Name: adminSessionCookie, Value: "dda_test"})
	withoutCSRF.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, withoutCSRF)
	if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), "ADMIN_CSRF_INVALID") {
		t.Fatalf("missing csrf status=%d body=%s", response.Code, response.Body.String())
	}

	fake.csrfOK = true
	withCSRF := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{"reason":"confirmed abuse"}`))
	withCSRF.AddCookie(&http.Cookie{Name: adminSessionCookie, Value: "dda_test"})
	withCSRF.Header.Set("Content-Type", "application/json")
	withCSRF.Header.Set("X-DD-Admin-CSRF", "valid")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, withCSRF)
	if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), "ADMIN_FORBIDDEN") {
		t.Fatalf("moderator high-risk status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAdminSessionRestoreUsesAdminCookie(t *testing.T) {
	principal := admin.Principal{AdminID: uuid.New(), SessionID: uuid.New(), Email: "support@example.test", Role: admin.RoleSupportReadOnly, ExpiresAt: time.Now().Add(time.Hour)}
	session := admin.SessionResult{Admin: admin.Identity{ID: principal.AdminID.String(), Email: principal.Email, Role: principal.Role}, SessionID: principal.SessionID.String(), CSRFToken: "csrf-from-server"}
	fake := &boundaryAdminService{principal: principal, session: session}
	handler := NewHandler(Config{AdminService: fake})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/admin/session", nil)
	request.AddCookie(&http.Cookie{Name: adminSessionCookie, Value: "dda_test"})
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "csrf-from-server") || !strings.Contains(response.Body.String(), "SUPPORT_READ_ONLY") {
		t.Fatalf("session restore status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAdminErrorMapsInvalidMFA(t *testing.T) {
	fake := &boundaryAdminService{AdminService: &mfaFailureAdminService{}}
	handler := NewHandler(Config{AdminService: fake.AdminService})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/admin/auth/mfa/verify", strings.NewReader(`{"challengeToken":"ddc_x","code":"123456"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || !strings.Contains(response.Body.String(), "ADMIN_MFA_INVALID") {
		t.Fatalf("invalid mfa status=%d body=%s", response.Code, response.Body.String())
	}
}

type fakeTelegramIntegration struct {
	status        stickers.TelegramRelayStatus
	validateCalls int
	activateCalls int
	lastToken     string
}

func (fake *fakeTelegramIntegration) Status() stickers.TelegramRelayStatus { return fake.status }
func (fake *fakeTelegramIntegration) ValidateToken(context.Context, string) (stickers.TelegramBotInfo, error) {
	fake.validateCalls++
	return stickers.TelegramBotInfo{ID: 42, Username: "dd_test_bot"}, nil
}
func (fake *fakeTelegramIntegration) ActivateToken(token string, source stickers.TelegramIntegrationSource, updatedAt *time.Time) error {
	fake.activateCalls++
	fake.lastToken = token
	fake.status = stickers.TelegramRelayStatus{Configured: true, Source: source, UpdatedAt: updatedAt}
	return nil
}
func (fake *fakeTelegramIntegration) Test(context.Context) (stickers.TelegramBotInfo, error) {
	return stickers.TelegramBotInfo{ID: 42, Username: "dd_test_bot"}, nil
}

func TestAdminTelegramIntegrationRequiresSuperAdminAndNeverEchoesToken(t *testing.T) {
	const token = "123456789:abcdefghijklmnopqrstuvwxyzABCDE"
	principal := admin.Principal{AdminID: uuid.New(), SessionID: uuid.New(), Email: "root@example.test", Role: admin.RoleSuperAdmin, ExpiresAt: time.Now().Add(time.Hour)}
	storedAt := time.Now().UTC()
	adminFake := &boundaryAdminService{
		principal: principal,
		session:   admin.SessionResult{Admin: admin.Identity{ID: principal.AdminID.String(), Email: principal.Email, Role: principal.Role}, SessionID: principal.SessionID.String()},
		csrfOK:    true,
		integrationSet: func(got admin.Principal, key, value string) (admin.IntegrationSecretStatus, error) {
			if got.Role != admin.RoleSuperAdmin || key != admin.IntegrationTelegramBotToken || value != token {
				t.Fatalf("unexpected integration persistence input role=%s key=%q valueMatch=%v", got.Role, key, value == token)
			}
			return admin.IntegrationSecretStatus{Key: key, Configured: true, UpdatedAt: storedAt}, nil
		},
	}
	telegramFake := &fakeTelegramIntegration{}
	handler := NewHandler(Config{AdminService: adminFake, TelegramIntegrationService: telegramFake})
	request := httptest.NewRequest(http.MethodPut, "/api/v1/admin/integrations/telegram-sticker", strings.NewReader(`{"botToken":"`+token+`"}`))
	request.AddCookie(&http.Cookie{Name: adminSessionCookie, Value: "dda_test"})
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-DD-Admin-CSRF", "valid")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("configure telegram status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), token) {
		t.Fatal("admin response echoed Telegram Bot Token")
	}
	if telegramFake.validateCalls != 1 || telegramFake.activateCalls != 1 || telegramFake.lastToken != token {
		t.Fatalf("unexpected telegram calls validate=%d activate=%d", telegramFake.validateCalls, telegramFake.activateCalls)
	}
}

func TestAdminTelegramIntegrationRejectsModeratorBeforeProviderValidation(t *testing.T) {
	principal := admin.Principal{AdminID: uuid.New(), SessionID: uuid.New(), Email: "mod@example.test", Role: admin.RoleModerator, ExpiresAt: time.Now().Add(time.Hour)}
	adminFake := &boundaryAdminService{
		principal: principal,
		session:   admin.SessionResult{Admin: admin.Identity{ID: principal.AdminID.String(), Email: principal.Email, Role: principal.Role}, SessionID: principal.SessionID.String()},
		csrfOK:    true,
	}
	telegramFake := &fakeTelegramIntegration{}
	handler := NewHandler(Config{AdminService: adminFake, TelegramIntegrationService: telegramFake})
	request := httptest.NewRequest(http.MethodPut, "/api/v1/admin/integrations/telegram-sticker", strings.NewReader(`{"botToken":"123456789:abcdefghijklmnopqrstuvwxyzABCDE"}`))
	request.AddCookie(&http.Cookie{Name: adminSessionCookie, Value: "dda_test"})
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-DD-Admin-CSRF", "valid")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), "ADMIN_FORBIDDEN") {
		t.Fatalf("moderator telegram status=%d body=%s", response.Code, response.Body.String())
	}
	if telegramFake.validateCalls != 0 {
		t.Fatalf("moderator unexpectedly triggered provider validation %d times", telegramFake.validateCalls)
	}
}

func TestAdminTelegramIntegrationStatusDoesNotExposeSecret(t *testing.T) {
	principal := admin.Principal{AdminID: uuid.New(), SessionID: uuid.New(), Email: "support@example.test", Role: admin.RoleSupportReadOnly, ExpiresAt: time.Now().Add(time.Hour)}
	adminFake := &boundaryAdminService{principal: principal, session: admin.SessionResult{Admin: admin.Identity{ID: principal.AdminID.String(), Email: principal.Email, Role: principal.Role}}}
	telegramFake := &fakeTelegramIntegration{status: stickers.TelegramRelayStatus{Configured: true, Source: stickers.TelegramIntegrationSourceAdmin}}
	handler := NewHandler(Config{AdminService: adminFake, TelegramIntegrationService: telegramFake})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/admin/integrations/telegram-sticker", nil)
	request.AddCookie(&http.Cookie{Name: adminSessionCookie, Value: "dda_test"})
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "ADMIN_OVERRIDE") {
		t.Fatalf("telegram status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(strings.ToLower(response.Body.String()), "token") {
		t.Fatalf("telegram status response contains token-shaped field: %s", response.Body.String())
	}
}

type mfaFailureAdminService struct{ AdminService }

func (*mfaFailureAdminService) VerifyMFA(context.Context, string, string, string, admin.ClientContext) (admin.IssuedSession, error) {
	return admin.IssuedSession{}, admin.ErrInvalidMFA
}
