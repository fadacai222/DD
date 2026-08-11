package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/datarights"
	"github.com/google/uuid"
)

type DataRightsService interface {
	RequestExport(ctx context.Context, principal account.Principal, idempotencyKey string) (datarights.ExportRequest, error)
	GetExport(ctx context.Context, principal account.Principal, requestID uuid.UUID) (datarights.ExportRequest, error)
	CreateExportDownload(ctx context.Context, principal account.Principal, requestID uuid.UUID) (datarights.ExportDownload, error)
	RequestDeletion(ctx context.Context, principal account.Principal, input datarights.RequestDeletionInput, idempotencyKey string) (datarights.DeletionRequest, error)
	GetDeletion(ctx context.Context, principal account.Principal, requestID uuid.UUID) (datarights.DeletionRequest, error)
	CancelDeletion(ctx context.Context, principal account.Principal, requestID uuid.UUID) (datarights.DeletionRequest, error)
}

func (s *server) handleDataExportRequests(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	if s.dataRights == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "DATA_RIGHTS_UNAVAILABLE", "Data rights service is unavailable")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	idempotencyKey, ok := requireIdempotencyKey(response, request)
	if !ok {
		return
	}
	result, err := s.dataRights.RequestExport(request.Context(), principal, idempotencyKey)
	if err != nil {
		s.writeDataRightsError(response, err)
		return
	}
	writeSuccess(response, http.StatusAccepted, map[string]any{"export": result})
}

func (s *server) handleDataExportRequestByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	if s.dataRights == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "DATA_RIGHTS_UNAVAILABLE", "Data rights service is unavailable")
		return
	}
	path := strings.TrimPrefix(request.URL.Path, "/api/v1/data-rights/exports/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 || len(parts) > 2 {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Resource not found")
		return
	}
	requestID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_DATA_EXPORT_ID", "Data export id is invalid")
		return
	}
	if len(parts) == 1 {
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		result, err := s.dataRights.GetExport(request.Context(), principal, requestID)
		if err != nil {
			s.writeDataRightsError(response, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"export": result})
		return
	}
	if parts[1] != "download" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Resource not found")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	result, err := s.dataRights.CreateExportDownload(request.Context(), principal, requestID)
	if err != nil {
		s.writeDataRightsError(response, err)
		return
	}
	response.Header().Set("Cache-Control", "no-store")
	writeSuccess(response, http.StatusOK, map[string]any{"download": result})
}

func (s *server) handleAccountDeletionRequests(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	if s.dataRights == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "DATA_RIGHTS_UNAVAILABLE", "Data rights service is unavailable")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	idempotencyKey, ok := requireIdempotencyKey(response, request)
	if !ok {
		return
	}
	var input datarights.RequestDeletionInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.dataRights.RequestDeletion(request.Context(), principal, input, idempotencyKey)
	if err != nil {
		s.writeDataRightsError(response, err)
		return
	}
	writeSuccess(response, http.StatusAccepted, map[string]any{"accountDeletion": result})
}

func (s *server) handleAccountDeletionRequestByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	if s.dataRights == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "DATA_RIGHTS_UNAVAILABLE", "Data rights service is unavailable")
		return
	}
	path := strings.TrimPrefix(request.URL.Path, "/api/v1/data-rights/account-deletion/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 || len(parts) > 2 {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Resource not found")
		return
	}
	requestID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ACCOUNT_DELETION_ID", "Account deletion id is invalid")
		return
	}
	if len(parts) == 1 {
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		result, err := s.dataRights.GetDeletion(request.Context(), principal, requestID)
		if err != nil {
			s.writeDataRightsError(response, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"accountDeletion": result})
		return
	}
	if parts[1] != "cancel" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Resource not found")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	result, err := s.dataRights.CancelDeletion(request.Context(), principal, requestID)
	if err != nil {
		s.writeDataRightsError(response, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"accountDeletion": result})
}

func requireIdempotencyKey(response http.ResponseWriter, request *http.Request) (string, bool) {
	key := strings.TrimSpace(request.Header.Get("Idempotency-Key"))
	if key == "" {
		writeAPIError(response, http.StatusBadRequest, "IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key header is required")
		return "", false
	}
	return key, true
}

func (s *server) writeDataRightsError(response http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, datarights.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_DATA_RIGHTS_REQUEST", "Data rights request is invalid")
	case errors.Is(err, datarights.ErrInvalidCredentials):
		writeAPIError(response, http.StatusForbidden, "REAUTHENTICATION_FAILED", "Current password verification failed")
	case errors.Is(err, datarights.ErrNotFound):
		// Intentionally identical for nonexistent and other users' request ids.
		writeAPIError(response, http.StatusNotFound, "DATA_RIGHTS_REQUEST_NOT_FOUND", "Data rights request was not found")
	case errors.Is(err, datarights.ErrNotReady):
		writeAPIError(response, http.StatusConflict, "EXPORT_NOT_READY", "Data export is not ready")
	case errors.Is(err, datarights.ErrExpired):
		writeAPIError(response, http.StatusGone, "EXPORT_EXPIRED", "Data export has expired")
	case errors.Is(err, datarights.ErrCancellationClosed):
		writeAPIError(response, http.StatusConflict, "CANCELLATION_WINDOW_CLOSED", "Account deletion can no longer be cancelled")
	case errors.Is(err, datarights.ErrAccountNotActive):
		writeAPIError(response, http.StatusConflict, "ACCOUNT_NOT_ACTIVE", "Account is not active")
	case errors.Is(err, datarights.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "DATA_RIGHTS_UNAVAILABLE", "Data rights service is unavailable")
	default:
		s.logger.Error("data rights request failed", "error", err)
		writeAPIError(response, http.StatusInternalServerError, "INTERNAL_ERROR", "Internal server error")
	}
}
