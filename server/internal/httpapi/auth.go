package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/registration"
	"github.com/google/uuid"
)

type AuthService interface {
	SendRegistrationCode(ctx context.Context, email, remoteAddress string) error
	Register(ctx context.Context, input registration.RegisterInput) (account.AuthSession, error)
	Login(ctx context.Context, input account.LoginInput) (account.AuthSession, error)
	Refresh(ctx context.Context, refreshToken string) (account.AuthSession, error)
	SendPasswordResetCode(ctx context.Context, email string) error
	ResetPassword(ctx context.Context, input account.ResetPasswordInput) error
	AuthenticateAccessToken(ctx context.Context, raw string) (account.Principal, error)
	GetMe(ctx context.Context, principal account.Principal) (account.Me, error)
	UpdateMe(ctx context.Context, principal account.Principal, input account.UpdateMeInput) (account.Me, error)
	SendEmailChangeCode(ctx context.Context, principal account.Principal, email string) error
	ChangeEmail(ctx context.Context, principal account.Principal, input account.ChangeEmailInput) (account.Me, error)
	PutProfileAvatar(ctx context.Context, principal account.Principal, contentType string, image []byte) (time.Time, error)
	GetProfileAvatar(ctx context.Context, userID uuid.UUID) (account.ProfileAvatar, error)
	DeleteProfileAvatar(ctx context.Context, principal account.Principal) error
	ListDevices(ctx context.Context, principal account.Principal) ([]account.ManagedDevice, error)
	ClearRevokedDevices(ctx context.Context, principal account.Principal) (int64, error)
	RevokeDevice(ctx context.Context, principal account.Principal, deviceID uuid.UUID) error
	RevokeAllDevices(ctx context.Context, principal account.Principal) error
}

type emailCodeRequest struct {
	Email   string `json:"email"`
	Purpose string `json:"purpose"`
}

type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

func (s *server) handleAuthEmailCodes(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAuthService(response) || !requireJSON(response, request) {
		return
	}
	var input emailCodeRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	if strings.ToLower(strings.TrimSpace(input.Purpose)) != "register" {
		writeAPIError(response, http.StatusBadRequest, "INVALID_PURPOSE", "Only register verification codes are supported")
		return
	}
	if err := s.auth.SendRegistrationCode(request.Context(), input.Email, request.RemoteAddr); err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	response.Header().Set("Retry-After", strconv.Itoa(60))
	writeSuccess(response, http.StatusAccepted, map[string]any{
		"accepted":          true,
		"retryAfterSeconds": 60,
	})
}

func (s *server) handleAuthRegister(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAuthService(response) || !requireJSON(response, request) {
		return
	}
	var input registration.RegisterInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.auth.Register(request.Context(), input)
	if err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	s.writeAuthSession(response, request, http.StatusCreated, result)
}

func (s *server) handleAuthLogin(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAuthService(response) || !requireJSON(response, request) {
		return
	}
	var input account.LoginInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.auth.Login(request.Context(), input)
	if err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	s.writeAuthSession(response, request, http.StatusOK, result)
}

func (s *server) handleAuthRefresh(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAuthService(response) || !requireJSON(response, request) {
		return
	}
	var input refreshRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	refreshToken := strings.TrimSpace(input.RefreshToken)
	usedCookie := false
	if refreshToken == "" {
		if cookie, cookieErr := request.Cookie("dd_refresh"); cookieErr == nil {
			refreshToken = strings.TrimSpace(cookie.Value)
			usedCookie = true
		}
	}
	result, err := s.auth.Refresh(request.Context(), refreshToken)
	if err != nil {
		if usedCookie {
			s.clearRefreshCookie(response, request)
		}
		s.writeAuthError(response, request, err)
		return
	}
	s.writeAuthSession(response, request, http.StatusOK, result)
}

func (s *server) writeAuthSession(response http.ResponseWriter, request *http.Request, status int, result account.AuthSession) {
	tokens := map[string]any{
		"accessToken":      result.Tokens.AccessToken,
		"accessExpiresAt":  result.Tokens.AccessExpiresAt,
		"refreshExpiresAt": result.Tokens.RefreshExpiresAt,
	}
	if result.Device.Platform == "WEB" {
		s.setRefreshCookie(response, request, result.Tokens.RefreshToken, result.Tokens.RefreshExpiresAt)
	} else {
		tokens["refreshToken"] = result.Tokens.RefreshToken
	}
	writeSuccess(response, status, map[string]any{
		"user":   result.User,
		"device": result.Device,
		"tokens": tokens,
	})
}

func (s *server) setRefreshCookie(response http.ResponseWriter, request *http.Request, token string, expiresAt time.Time) {
	maxAge := int(expiresAt.Sub(s.now().UTC()).Seconds())
	if maxAge < 1 {
		maxAge = 1
	}
	http.SetCookie(response, &http.Cookie{
		Name:     "dd_refresh",
		Value:    token,
		Path:     "/api/v1/auth",
		Expires:  expiresAt.UTC(),
		MaxAge:   maxAge,
		HttpOnly: true,
		Secure:   request.TLS != nil || strings.HasPrefix(strings.ToLower(s.publicBaseURL), "https://"),
		SameSite: http.SameSiteLaxMode,
	})
}

func (s *server) clearRefreshCookie(response http.ResponseWriter, request *http.Request) {
	http.SetCookie(response, &http.Cookie{
		Name:     "dd_refresh",
		Value:    "",
		Path:     "/api/v1/auth",
		MaxAge:   -1,
		Expires:  time.Unix(1, 0).UTC(),
		HttpOnly: true,
		Secure:   request.TLS != nil || strings.HasPrefix(strings.ToLower(s.publicBaseURL), "https://"),
		SameSite: http.SameSiteLaxMode,
	})
}

func requireJSON(response http.ResponseWriter, request *http.Request) bool {
	if !isJSONContentType(request.Header.Get("Content-Type")) {
		writeAPIError(response, http.StatusUnsupportedMediaType, "JSON_REQUIRED", "Content-Type must be application/json")
		return false
	}
	return true
}

func (s *server) requireAuthService(response http.ResponseWriter) bool {
	if s.auth == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "AUTH_SERVICE_UNAVAILABLE", "Authentication service is not configured")
		return false
	}
	return true
}

func (s *server) writeAuthError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, account.ErrRegistrationDisabled):
		writeAPIError(response, http.StatusForbidden, "REGISTRATION_DISABLED", "Registration is not available on this instance")
	case errors.Is(err, account.ErrRateLimited):
		response.Header().Set("Retry-After", "60")
		writeAPIError(response, http.StatusTooManyRequests, "RATE_LIMITED", "Please wait before requesting another verification code")
	case errors.Is(err, account.ErrLoginRateLimited):
		response.Header().Set("Retry-After", "900")
		writeAPIError(response, http.StatusTooManyRequests, "LOGIN_RATE_LIMITED", "Too many failed login attempts; try again later")
	case errors.Is(err, account.ErrInvalidCode):
		writeAPIError(response, http.StatusBadRequest, "INVALID_VERIFICATION_CODE", "Verification code is invalid or expired")
	case errors.Is(err, account.ErrEmailExists):
		writeAPIError(response, http.StatusConflict, "EMAIL_ALREADY_REGISTERED", "Email is already registered")
	case errors.Is(err, account.ErrHandleExists):
		writeAPIError(response, http.StatusConflict, "HANDLE_UNAVAILABLE", "Handle is unavailable")
	case errors.Is(err, account.ErrInvalidCredentials):
		writeAPIError(response, http.StatusUnauthorized, "INVALID_CREDENTIALS", "Email or password is incorrect")
	case errors.Is(err, account.ErrDeviceSessionRevoked):
		writeAPIError(response, http.StatusUnauthorized, "DEVICE_SESSION_REVOKED", "Device session has been revoked")
	case errors.Is(err, account.ErrInvalidRefreshToken), errors.Is(err, account.ErrRefreshReuse), errors.Is(err, account.ErrUnauthorized):
		writeAPIError(response, http.StatusUnauthorized, "SESSION_EXPIRED", "Session is no longer valid")
	case errors.Is(err, account.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "FORBIDDEN", "Operation is not allowed")
	case errors.Is(err, account.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
	case errors.Is(err, account.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "AUTH_SERVICE_UNAVAILABLE", "Authentication service is not configured")
	default:
		// Validation failures are deliberately returned without internal error details.
		if isAuthValidationError(err) {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		s.logger.Error("authentication request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "AUTH_INTERNAL_ERROR", "Authentication request failed")
	}
}

func isAuthValidationError(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	for _, fragment := range []string{
		"invalid email", "verification code", "password must", "password exceeds", "password is too",
		"invalid handle", "display name", "invalid profile", "device name", "unsupported device platform", "app version",
	} {
		if strings.Contains(text, fragment) {
			return true
		}
	}
	return false
}
