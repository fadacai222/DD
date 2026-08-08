package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/registration"
	"github.com/google/uuid"
)

type fakeAuthService struct {
	sendErr       error
	registerErr   error
	loginErr      error
	refreshErr    error
	loginResult   *account.AuthSession
	refreshResult *account.AuthSession
	lastEmail     string
	lastRefresh   string
}

func (fake *fakeAuthService) SendRegistrationCode(_ context.Context, email, _ string) error {
	fake.lastEmail = email
	return fake.sendErr
}

func (fake *fakeAuthService) Register(_ context.Context, _ registration.RegisterInput) (account.AuthSession, error) {
	return testAuthSession(), fake.registerErr
}

func (fake *fakeAuthService) Login(_ context.Context, _ account.LoginInput) (account.AuthSession, error) {
	if fake.loginResult != nil {
		return *fake.loginResult, fake.loginErr
	}
	return testAuthSession(), fake.loginErr
}

func (fake *fakeAuthService) Refresh(_ context.Context, token string) (account.AuthSession, error) {
	fake.lastRefresh = token
	if fake.refreshResult != nil {
		return *fake.refreshResult, fake.refreshErr
	}
	return testAuthSession(), fake.refreshErr
}

func (fake *fakeAuthService) SendPasswordResetCode(_ context.Context, _ string) error { return nil }
func (fake *fakeAuthService) ResetPassword(_ context.Context, _ account.ResetPasswordInput) error {
	return nil
}
func (fake *fakeAuthService) AuthenticateAccessToken(_ context.Context, _ string) (account.Principal, error) {
	return account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}, nil
}
func (fake *fakeAuthService) GetMe(_ context.Context, _ account.Principal) (account.Me, error) {
	return account.Me{}, nil
}
func (fake *fakeAuthService) UpdateMe(_ context.Context, _ account.Principal, input account.UpdateMeInput) (account.Me, error) {
	return account.Me{Profile: account.Profile{DisplayName: input.DisplayName, Bio: input.Bio}, Privacy: input.Privacy}, nil
}
func (fake *fakeAuthService) PutProfileAvatar(_ context.Context, _ account.Principal, _ string, _ []byte) (time.Time, error) {
	return time.Date(2026, 8, 8, 9, 0, 0, 0, time.UTC), nil
}
func (fake *fakeAuthService) GetProfileAvatar(_ context.Context, _ uuid.UUID) (account.ProfileAvatar, error) {
	return account.ProfileAvatar{ContentType: "image/png", Bytes: []byte{0x89, 0x50}, UpdatedAt: time.Date(2026, 8, 8, 9, 0, 0, 0, time.UTC)}, nil
}
func (fake *fakeAuthService) DeleteProfileAvatar(_ context.Context, _ account.Principal) error {
	return nil
}
func (fake *fakeAuthService) ListDevices(_ context.Context, _ account.Principal) ([]account.ManagedDevice, error) {
	return nil, nil
}
func (fake *fakeAuthService) RevokeDevice(_ context.Context, _ account.Principal, _ uuid.UUID) error {
	return nil
}
func (fake *fakeAuthService) RevokeAllDevices(_ context.Context, _ account.Principal) error {
	return nil
}

func TestAuthEmailCodeEndpointAcceptsRegistrationRequest(t *testing.T) {
	fake := &fakeAuthService{}
	handler := NewHandler(Config{AuthService: fake})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/register/email/send-code", strings.NewReader(`{"email":"User@example.com","purpose":"register"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusAccepted {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if fake.lastEmail != "User@example.com" {
		t.Fatalf("email = %q", fake.lastEmail)
	}
	if response.Header().Get("Retry-After") != "60" {
		t.Fatalf("Retry-After = %q", response.Header().Get("Retry-After"))
	}
}

func TestAuthLoginUsesUnifiedCredentialError(t *testing.T) {
	fake := &fakeAuthService{loginErr: account.ErrInvalidCredentials}
	handler := NewHandler(Config{AuthService: fake})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"nobody@example.com","password":"wrong-password","device":{"name":"Chrome","platform":"web"}}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || !strings.Contains(response.Body.String(), `"code":"INVALID_CREDENTIALS"`) {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(strings.ToLower(response.Body.String()), "not found") {
		t.Fatalf("response leaks account existence: %s", response.Body.String())
	}
}

func TestAuthRefreshReuseReturnsExpiredSessionWithoutDetail(t *testing.T) {
	fake := &fakeAuthService{refreshErr: account.ErrRefreshReuse}
	handler := NewHandler(Config{AuthService: fake})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/token/refresh", strings.NewReader(`{"refreshToken":"secret-value"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || !strings.Contains(response.Body.String(), `"code":"SESSION_EXPIRED"`) {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if fake.lastRefresh != "secret-value" {
		t.Fatalf("refresh token = %q", fake.lastRefresh)
	}
	if strings.Contains(strings.ToLower(response.Body.String()), "reuse") {
		t.Fatalf("response exposes refresh reuse detail: %s", response.Body.String())
	}
}

func TestWebLoginUsesHttpOnlyRefreshCookieAndOmitsRefreshToken(t *testing.T) {
	fake := &fakeAuthService{}
	handler := NewHandler(Config{AuthService: fake, PublicBaseURL: "https://chat.example.com"})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"alice@example.com","password":"correct-password","device":{"name":"DD Web","platform":"WEB"}}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), `"refreshToken"`) {
		t.Fatalf("web response exposed refresh token: %s", response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"data"`) || !strings.Contains(response.Body.String(), `"requestId"`) {
		t.Fatalf("web response is not a v1 envelope: %s", response.Body.String())
	}
	cookie := response.Header().Get("Set-Cookie")
	for _, required := range []string{"dd_refresh=refresh", "HttpOnly", "Secure", "SameSite=Lax", "Path=/api/v1/auth"} {
		if !strings.Contains(cookie, required) {
			t.Fatalf("Set-Cookie %q missing %q", cookie, required)
		}
	}
}

func TestNativeLoginReturnsRefreshTokenInEnvelopeWithoutCookie(t *testing.T) {
	session := testAuthSession()
	session.Device.Platform = "WINDOWS"
	fake := &fakeAuthService{loginResult: &session}
	handler := NewHandler(Config{AuthService: fake})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"alice@example.com","password":"correct-password","device":{"name":"DD Windows","platform":"WINDOWS"}}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"refreshToken":"refresh"`) {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if response.Header().Get("Set-Cookie") != "" {
		t.Fatalf("native login unexpectedly set cookie: %q", response.Header().Get("Set-Cookie"))
	}
}

func TestWebRefreshReadsHttpOnlyCookie(t *testing.T) {
	fake := &fakeAuthService{}
	handler := NewHandler(Config{AuthService: fake})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/token/refresh", strings.NewReader(`{}`))
	request.Header.Set("Content-Type", "application/json")
	request.AddCookie(&http.Cookie{Name: "dd_refresh", Value: "cookie-secret"})
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if fake.lastRefresh != "cookie-secret" {
		t.Fatalf("refresh token = %q", fake.lastRefresh)
	}
	if strings.Contains(response.Body.String(), `"refreshToken"`) {
		t.Fatalf("web refresh exposed refresh token: %s", response.Body.String())
	}
}

func TestAuthServiceUnavailableWithoutDatabaseBackedService(t *testing.T) {
	handler := NewHandler(Config{})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/register", strings.NewReader(`{}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"AUTH_SERVICE_UNAVAILABLE"`) {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
}

func testAuthSession() account.AuthSession {
	now := time.Date(2026, 8, 8, 0, 0, 0, 0, time.UTC)
	return account.AuthSession{
		User:   account.User{ID: "018f0000-0000-7000-8000-000000000001", Email: "alice@example.com", Handle: "alice", DisplayName: "Alice"},
		Device: account.Device{ID: "018f0000-0000-7000-8000-000000000002", Name: "Chrome", Platform: "WEB", AppVersion: "1"},
		Tokens: account.Tokens{AccessToken: "access", AccessExpiresAt: now.Add(15 * time.Minute), RefreshToken: "refresh", RefreshExpiresAt: now.Add(30 * 24 * time.Hour)},
	}
}
