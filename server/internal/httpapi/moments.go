package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/moments"
	"github.com/google/uuid"
)

type MomentsService interface {
	Create(ctx context.Context, principal account.Principal, input moments.CreateInput) (moments.Moment, []uuid.UUID, error)
	ListFeed(ctx context.Context, principal account.Principal, before *uuid.UUID, limit int) ([]moments.Moment, error)
	Get(ctx context.Context, principal account.Principal, momentID uuid.UUID) (moments.Moment, error)
	Delete(ctx context.Context, principal account.Principal, momentID uuid.UUID) ([]uuid.UUID, error)
	SetLike(ctx context.Context, principal account.Principal, momentID uuid.UUID, liked bool) (moments.Moment, []uuid.UUID, error)
	AddComment(ctx context.Context, principal account.Principal, momentID uuid.UUID, input moments.CommentInput) (moments.Moment, []uuid.UUID, error)
	DeleteComment(ctx context.Context, principal account.Principal, momentID, commentID uuid.UUID) (moments.Moment, []uuid.UUID, error)
	SetPreference(ctx context.Context, principal account.Principal, targetID uuid.UUID, input moments.PreferenceInput) (moments.Preference, error)
	ListPreferences(ctx context.Context, principal account.Principal) ([]moments.Preference, error)
}

func (s *server) handleMoments(response http.ResponseWriter, request *http.Request) {
	if request.URL.Path != "/api/v1/moments" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	principal, ok := s.requireMomentsPrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodGet:
		limit := 30
		if raw := strings.TrimSpace(request.URL.Query().Get("limit")); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil || parsed <= 0 || parsed > 50 {
				writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", "limit must be between 1 and 50")
				return
			}
			limit = parsed
		}
		var before *uuid.UUID
		if raw := strings.TrimSpace(request.URL.Query().Get("before")); raw != "" {
			parsed, err := uuid.Parse(raw)
			if err != nil {
				writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", "before must be a UUID")
				return
			}
			before = &parsed
		}
		items, err := s.moments.ListFeed(request.Context(), principal, before, limit)
		if err != nil {
			s.writeMomentsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"items": items})
	case http.MethodPost:
		if !requireJSON(response, request) {
			return
		}
		var input moments.CreateInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", err.Error())
			return
		}
		item, recipients, err := s.moments.Create(request.Context(), principal, input)
		if err != nil {
			s.writeMomentsError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "moment-created")
		writeSuccess(response, http.StatusCreated, item)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPost)
	}
}

func (s *server) handleMomentByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMomentsPrincipal(response, request)
	if !ok {
		return
	}
	raw := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/moments/"), "/")
	parts := strings.Split(raw, "/")
	if len(parts) < 1 || len(parts) > 3 || strings.TrimSpace(parts[0]) == "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	momentID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", "momentId must be a UUID")
		return
	}
	if len(parts) == 1 {
		s.handleMomentRoot(response, request, principal, momentID)
		return
	}
	switch parts[1] {
	case "like":
		if len(parts) != 2 {
			writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
			return
		}
		liked := request.Method == http.MethodPut
		if request.Method != http.MethodPut && request.Method != http.MethodDelete {
			methodNotAllowed(response, http.MethodPut, http.MethodDelete)
			return
		}
		item, recipients, err := s.moments.SetLike(request.Context(), principal, momentID, liked)
		if err != nil {
			s.writeMomentsError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "moment-like-changed")
		writeSuccess(response, http.StatusOK, item)
	case "comments":
		if len(parts) == 2 {
			if request.Method != http.MethodPost {
				methodNotAllowed(response, http.MethodPost)
				return
			}
			if !requireJSON(response, request) {
				return
			}
			var input moments.CommentInput
			if err := decodeSingleJSON(response, request, &input); err != nil {
				writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", err.Error())
				return
			}
			item, recipients, err := s.moments.AddComment(request.Context(), principal, momentID, input)
			if err != nil {
				s.writeMomentsError(response, request, err)
				return
			}
			s.publishEventAvailable(recipients, "moment-comment-created")
			writeSuccess(response, http.StatusCreated, item)
			return
		}
		if len(parts) != 3 || request.Method != http.MethodDelete {
			if request.Method != http.MethodDelete {
				methodNotAllowed(response, http.MethodDelete)
				return
			}
			writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
			return
		}
		commentID, parseErr := uuid.Parse(parts[2])
		if parseErr != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", "commentId must be a UUID")
			return
		}
		item, recipients, err := s.moments.DeleteComment(request.Context(), principal, momentID, commentID)
		if err != nil {
			s.writeMomentsError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "moment-comment-deleted")
		writeSuccess(response, http.StatusOK, item)
	default:
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
	}
}

func (s *server) handleMomentRoot(response http.ResponseWriter, request *http.Request, principal account.Principal, momentID uuid.UUID) {
	switch request.Method {
	case http.MethodGet:
		item, err := s.moments.Get(request.Context(), principal, momentID)
		if err != nil {
			s.writeMomentsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, item)
	case http.MethodDelete:
		recipients, err := s.moments.Delete(request.Context(), principal, momentID)
		if err != nil {
			s.writeMomentsError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "moment-deleted")
		writeSuccess(response, http.StatusOK, map[string]any{"deleted": true})
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodDelete)
	}
}

func (s *server) handleMomentPreferences(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMomentsPrincipal(response, request)
	if !ok {
		return
	}
	if request.URL.Path == "/api/v1/moment-preferences" {
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		items, err := s.moments.ListPreferences(request.Context(), principal)
		if err != nil {
			s.writeMomentsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"items": items})
		return
	}
	if request.Method != http.MethodPatch {
		methodNotAllowed(response, http.MethodPatch)
		return
	}
	raw := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/moment-preferences/"), "/")
	targetID, err := uuid.Parse(raw)
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", "userId must be a UUID")
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input moments.PreferenceInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", err.Error())
		return
	}
	item, err := s.moments.SetPreference(request.Context(), principal, targetID, input)
	if err != nil {
		s.writeMomentsError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, item)
}

func (s *server) requireMomentsPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.moments == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "MOMENTS_SERVICE_UNAVAILABLE", "Moments service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) writeMomentsError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, moments.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_MOMENT_REQUEST", "Moment input is invalid")
	case errors.Is(err, moments.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "MOMENT_NOT_FOUND", "Moment resource was not found")
	case errors.Is(err, moments.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "MOMENT_FORBIDDEN", "Moment operation is not allowed")
	case errors.Is(err, moments.ErrConflict):
		writeAPIError(response, http.StatusConflict, "MOMENT_STATE_CONFLICT", "Moment state does not allow this operation")
	case errors.Is(err, moments.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "MOMENTS_SERVICE_UNAVAILABLE", "Moments service is not configured")
	default:
		s.logger.Error("moments request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "MOMENTS_INTERNAL_ERROR", "Moments request failed")
	}
}
