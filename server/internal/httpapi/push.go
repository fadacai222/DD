package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/push"
)

type PushService interface {
	GetPreferences(ctx context.Context, principal account.Principal) (push.Preferences, error)
	UpdatePreferences(ctx context.Context, principal account.Principal, input push.UpdatePreferencesInput) (push.Preferences, error)
	RegisterEndpoint(ctx context.Context, principal account.Principal, input push.RegisterEndpointInput) (push.Endpoint, error)
	ListEndpoints(ctx context.Context, principal account.Principal) ([]push.Endpoint, error)
	DeleteEndpoint(ctx context.Context, principal account.Principal, provider string) error
	EnqueueTest(ctx context.Context, principal account.Principal) error
}

func (s *server) handlePushPreferences(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePushPrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodGet:
		item, err := s.push.GetPreferences(request.Context(), principal)
		if err != nil {
			s.writePushError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, item)
	case http.MethodPut, http.MethodPatch:
		if !requireJSON(response, request) {
			return
		}
		var input push.UpdatePreferencesInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_PUSH_REQUEST", err.Error())
			return
		}
		item, err := s.push.UpdatePreferences(request.Context(), principal, input)
		if err != nil {
			s.writePushError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, item)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPut, http.MethodPatch)
	}
}

func (s *server) handlePushEndpoints(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePushPrincipal(response, request)
	if !ok {
		return
	}
	if request.URL.Path != "/api/v1/push/endpoints" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	switch request.Method {
	case http.MethodGet:
		items, err := s.push.ListEndpoints(request.Context(), principal)
		if err != nil {
			s.writePushError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"items": items})
	case http.MethodPost, http.MethodPut:
		if !requireJSON(response, request) {
			return
		}
		var input push.RegisterEndpointInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_PUSH_REQUEST", err.Error())
			return
		}
		item, err := s.push.RegisterEndpoint(request.Context(), principal, input)
		if err != nil {
			s.writePushError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, item)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPost, http.MethodPut)
	}
}

func (s *server) handlePushEndpointByProvider(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePushPrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodDelete {
		methodNotAllowed(response, http.MethodDelete)
		return
	}
	provider := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/push/endpoints/"), "/")
	if provider == "" || strings.Contains(provider, "/") {
		writeAPIError(response, http.StatusBadRequest, "INVALID_PUSH_REQUEST", "provider is required")
		return
	}
	if err := s.push.DeleteEndpoint(request.Context(), principal, provider); err != nil {
		s.writePushError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"deleted": true})
}

func (s *server) handlePushTest(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requirePushPrincipal(response, request)
	if !ok {
		return
	}
	if err := s.push.EnqueueTest(request.Context(), principal); err != nil {
		s.writePushError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusAccepted, map[string]any{"queued": true})
}

func (s *server) requirePushPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.push == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "PUSH_SERVICE_UNAVAILABLE", "Push service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) writePushError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, push.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_PUSH_REQUEST", "Push request is invalid")
	case errors.Is(err, push.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "PUSH_FORBIDDEN", "Push operation is not allowed")
	case errors.Is(err, push.ErrConflict):
		writeAPIError(response, http.StatusConflict, "PUSH_ENDPOINT_CONFLICT", "Push endpoint is already bound to another account")
	case errors.Is(err, push.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "PUSH_ENDPOINT_NOT_FOUND", "Push endpoint was not found")
	case errors.Is(err, push.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "PUSH_SERVICE_UNAVAILABLE", "Push service is not configured")
	default:
		s.logger.Error("push request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "PUSH_INTERNAL_ERROR", "Push request failed")
	}
}
