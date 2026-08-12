package httpapi

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
)

type passwordResetSendRequest struct {
	Email string `json:"email"`
}

type emailChangeSendRequest struct {
	Email string `json:"email"`
}

func (s *server) handlePasswordResetCode(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAuthService(response) || !requireJSON(response, request) {
		return
	}
	var input passwordResetSendRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	if err := s.auth.SendPasswordResetCode(request.Context(), input.Email); err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusAccepted, map[string]any{"accepted": true, "retryAfterSeconds": 60})
}

func (s *server) handlePasswordReset(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !s.requireAuthService(response) || !requireJSON(response, request) {
		return
	}
	var input account.ResetPasswordInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	if err := s.auth.ResetPassword(request.Context(), input); err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	s.clearRefreshCookie(response, request)
	writeSuccess(response, http.StatusOK, map[string]any{"reset": true})
}

func (s *server) handleMe(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodGet:
		result, err := s.auth.GetMe(request.Context(), principal)
		if err != nil {
			s.writeAuthError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	case http.MethodPatch:
		if !requireJSON(response, request) {
			return
		}
		var input account.UpdateMeInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		result, err := s.auth.UpdateMe(request.Context(), principal, input)
		if err != nil {
			s.writeAuthError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	default:
		response.Header().Set("Allow", "GET, PATCH")
		writeAPIError(response, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Method is not allowed")
	}
}

func (s *server) handleMeEmailChangeCode(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requirePrincipal(response, request)
	if !ok || !requireJSON(response, request) {
		return
	}
	var input emailChangeSendRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	if err := s.auth.SendEmailChangeCode(request.Context(), principal, input.Email); err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusAccepted, map[string]any{"accepted": true, "retryAfterSeconds": 60})
}

func (s *server) handleMeEmail(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPatch {
		methodNotAllowed(response, http.MethodPatch)
		return
	}
	principal, ok := s.requirePrincipal(response, request)
	if !ok || !requireJSON(response, request) {
		return
	}
	var input account.ChangeEmailInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.auth.ChangeEmail(request.Context(), principal, input)
	if err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleMeAvatar(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodPut:
		request.Body = http.MaxBytesReader(response, request.Body, account.MaxProfileAvatarBytes+1)
		image, err := io.ReadAll(request.Body)
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				writeAPIError(response, http.StatusRequestEntityTooLarge, "AVATAR_TOO_LARGE", "Avatar must not exceed 2 MiB")
				return
			}
			writeAPIError(response, http.StatusBadRequest, "INVALID_AVATAR", "Avatar payload could not be read")
			return
		}
		updatedAt, err := s.auth.PutProfileAvatar(request.Context(), principal, request.Header.Get("Content-Type"), image)
		if err != nil {
			if errors.Is(err, account.ErrInvalidAvatar) {
				writeAPIError(response, http.StatusBadRequest, "INVALID_AVATAR", "Avatar must be JPEG, PNG or WebP and no larger than 2 MiB")
				return
			}
			s.writeAuthError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"updatedAt": updatedAt})
	case http.MethodDelete:
		if err := s.auth.DeleteProfileAvatar(request.Context(), principal); err != nil {
			s.writeAuthError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"deleted": true})
	default:
		methodNotAllowed(response, http.MethodPut, http.MethodDelete)
	}
}

func (s *server) handleUserAvatar(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	if _, ok := s.requirePrincipal(response, request); !ok {
		return
	}
	userID, err := uuid.Parse(
		strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/avatars/"), "/"),
	)
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_USER_ID", "User id is invalid")
		return
	}
	avatar, err := s.auth.GetProfileAvatar(request.Context(), userID)
	if err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	etag := fmt.Sprintf("\"%x\"", avatar.UpdatedAt.UnixNano())
	if request.Header.Get("If-None-Match") == etag {
		response.WriteHeader(http.StatusNotModified)
		return
	}
	response.Header().Set("Content-Type", avatar.ContentType)
	response.Header().Set("Content-Length", fmt.Sprintf("%d", len(avatar.Bytes)))
	response.Header().Set("Cache-Control", "private, max-age=60")
	response.Header().Set("ETag", etag)
	response.WriteHeader(http.StatusOK)
	_, _ = response.Write(avatar.Bytes)
}

func (s *server) handleDevices(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	devices, err := s.auth.ListDevices(request.Context(), principal)
	if err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"devices": devices})
}

func (s *server) handleDeviceByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodDelete {
		methodNotAllowed(response, http.MethodDelete)
		return
	}
	rawID := strings.TrimPrefix(request.URL.Path, "/api/v1/devices/")
	if rawID == "revoked" {
		count, err := s.auth.ClearRevokedDevices(request.Context(), principal)
		if err != nil {
			s.writeAuthError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"clearedCount": count})
		return
	}
	deviceID, err := uuid.Parse(rawID)
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_DEVICE_ID", "Device id is invalid")
		return
	}
	if err := s.auth.RevokeDevice(request.Context(), principal, deviceID); err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	if deviceID == principal.DeviceID {
		s.clearRefreshCookie(response, request)
	}
	writeSuccess(response, http.StatusOK, map[string]any{"revoked": true})
}

func (s *server) handleLogoutAll(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	if err := s.auth.RevokeAllDevices(request.Context(), principal); err != nil {
		s.writeAuthError(response, request, err)
		return
	}
	s.clearRefreshCookie(response, request)
	writeSuccess(response, http.StatusOK, map[string]any{"revoked": true})
}

func (s *server) requirePrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if !s.requireAuthService(response) {
		return account.Principal{}, false
	}
	authorization := strings.TrimSpace(request.Header.Get("Authorization"))
	const prefix = "Bearer "
	if len(authorization) <= len(prefix) || !strings.EqualFold(authorization[:len(prefix)], prefix) {
		writeAPIError(response, http.StatusUnauthorized, "UNAUTHORIZED", "Valid access token is required")
		return account.Principal{}, false
	}
	principal, err := s.auth.AuthenticateAccessToken(request.Context(), strings.TrimSpace(authorization[len(prefix):]))
	if errors.Is(err, account.ErrDeviceSessionRevoked) {
		writeAPIError(response, http.StatusUnauthorized, "DEVICE_SESSION_REVOKED", "Device session has been revoked")
		return account.Principal{}, false
	}
	if err != nil {
		writeAPIError(response, http.StatusUnauthorized, "UNAUTHORIZED", "Valid access token is required")
		return account.Principal{}, false
	}
	return principal, true
}

func isAccountManagementError(err error) bool {
	return errors.Is(err, account.ErrUnauthorized) || errors.Is(err, account.ErrForbidden) || errors.Is(err, account.ErrNotFound) || errors.Is(err, account.ErrLoginRateLimited)
}
