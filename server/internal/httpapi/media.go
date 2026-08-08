package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/media"
	"github.com/google/uuid"
)

type MediaService interface {
	CreateUpload(ctx context.Context, principal account.Principal, input media.CreateUploadInput) (media.UploadGrant, error)
	CompleteUpload(ctx context.Context, principal account.Principal, uploadID uuid.UUID) (media.CompleteUploadResult, error)
	GetMedia(ctx context.Context, principal account.Principal, mediaID uuid.UUID) (media.MediaObject, error)
	CreateDownloadURL(ctx context.Context, principal account.Principal, mediaID uuid.UUID) (string, time.Time, error)
}

func (s *server) handleMediaUploads(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requireMediaPrincipal(response, request)
	if !ok || !requireJSON(response, request) {
		return
	}
	var input media.CreateUploadInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.media.CreateUpload(request.Context(), principal, input)
	if err != nil {
		s.writeMediaError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusCreated, result)
}

func (s *server) handleMediaUploadByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMediaPrincipal(response, request)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/media/uploads/"), "/"), "/")
	if len(parts) != 2 || parts[1] != "complete" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	uploadID, err := uuid.Parse(strings.TrimSpace(parts[0]))
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "uploadId must be a UUID")
		return
	}
	result, err := s.media.CompleteUpload(request.Context(), principal, uploadID)
	if err != nil {
		s.writeMediaError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleMediaByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMediaPrincipal(response, request)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/media/"), "/"), "/")
	if len(parts) < 1 || len(parts) > 2 || strings.TrimSpace(parts[0]) == "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	mediaID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "mediaId must be a UUID")
		return
	}
	if len(parts) == 1 {
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		result, err := s.media.GetMedia(request.Context(), principal, mediaID)
		if err != nil {
			s.writeMediaError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
		return
	}
	if parts[1] != "download-url" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	url, expiresAt, err := s.media.CreateDownloadURL(request.Context(), principal, mediaID)
	if err != nil {
		s.writeMediaError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"downloadUrl": url, "expiresAt": expiresAt})
}

func (s *server) requireMediaPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.media == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "MEDIA_SERVICE_UNAVAILABLE", "Media service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) writeMediaError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, media.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested media resource was not found")
	case errors.Is(err, media.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "MEDIA_FORBIDDEN", "Media operation is not allowed")
	case errors.Is(err, media.ErrQuotaExceeded):
		writeAPIError(response, http.StatusRequestEntityTooLarge, "MEDIA_QUOTA_EXCEEDED", "Media upload exceeds the current quota")
	case errors.Is(err, media.ErrUploadExpired):
		writeAPIError(response, http.StatusGone, "MEDIA_UPLOAD_EXPIRED", "Media upload reservation has expired")
	case errors.Is(err, media.ErrConflict), errors.Is(err, media.ErrObjectMismatch):
		writeAPIError(response, http.StatusConflict, "MEDIA_UPLOAD_MISMATCH", "Uploaded object does not match the reserved media")
	case errors.Is(err, media.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "Media request is invalid")
	case errors.Is(err, media.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "MEDIA_SERVICE_UNAVAILABLE", "Media service is unavailable")
	default:
		s.logger.Error("media request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "MEDIA_INTERNAL_ERROR", "Media request failed")
	}
}
