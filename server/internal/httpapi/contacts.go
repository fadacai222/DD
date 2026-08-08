package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/contacts"
	"github.com/google/uuid"
)

type ContactsService interface {
	SearchByHandle(ctx context.Context, principal account.Principal, handle string) (contacts.SearchResult, error)
	SendRequest(ctx context.Context, principal account.Principal, input contacts.SendRequestInput) (contacts.ContactRequest, error)
	AcceptRequest(ctx context.Context, principal account.Principal, requestID uuid.UUID) (contacts.ContactRequest, error)
	RejectRequest(ctx context.Context, principal account.Principal, requestID uuid.UUID) (contacts.ContactRequest, error)
	CancelRequest(ctx context.Context, principal account.Principal, requestID uuid.UUID) (contacts.ContactRequest, error)
	ListRequests(ctx context.Context, principal account.Principal, direction string, page, pageSize int) (contacts.Page[contacts.ContactRequest], error)
	ListContacts(ctx context.Context, principal account.Principal, page, pageSize int) (contacts.Page[contacts.Contact], error)
	UpdateContact(ctx context.Context, principal account.Principal, contactUserID uuid.UUID, input contacts.UpdateContactInput) (contacts.Contact, error)
	DeleteContact(ctx context.Context, principal account.Principal, contactUserID uuid.UUID) error
	BlockUser(ctx context.Context, principal account.Principal, blockedUserID uuid.UUID) (contacts.BlockedUser, error)
	UnblockUser(ctx context.Context, principal account.Principal, blockedUserID uuid.UUID) error
	ListBlocks(ctx context.Context, principal account.Principal, page, pageSize int) (contacts.Page[contacts.BlockedUser], error)
}

type blockUserRequest struct {
	UserID string `json:"userId"`
}

func (s *server) handleUserByHandle(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, ok := s.requireContactsPrincipal(response, request)
	if !ok {
		return
	}
	rawHandle := strings.TrimPrefix(request.URL.Path, "/api/v1/users/by-handle/")
	handle, err := url.PathUnescape(rawHandle)
	if err != nil || strings.TrimSpace(handle) == "" || strings.Contains(handle, "/") {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "A valid handle is required")
		return
	}
	result, err := s.contacts.SearchByHandle(request.Context(), principal, handle)
	if err != nil {
		s.writeContactsError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleContactRequests(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireContactsPrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodGet:
		page, pageSize, ok := parsePageQuery(response, request)
		if !ok {
			return
		}
		result, err := s.contacts.ListRequests(request.Context(), principal, request.URL.Query().Get("direction"), page, pageSize)
		if err != nil {
			s.writeContactsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	case http.MethodPost:
		if !requireJSON(response, request) {
			return
		}
		var input contacts.SendRequestInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		result, err := s.contacts.SendRequest(request.Context(), principal, input)
		if err != nil {
			s.writeContactsError(response, request, err)
			return
		}
		status := http.StatusCreated
		if result.Status == "ACCEPTED" {
			status = http.StatusOK
		}
		writeSuccess(response, status, result)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPost)
	}
}

func (s *server) handleContactRequestByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireContactsPrincipal(response, request)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/contact-requests/"), "/"), "/")
	if len(parts) < 1 || len(parts) > 2 {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	requestID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "requestId must be a UUID")
		return
	}

	if len(parts) == 1 {
		if request.Method != http.MethodDelete {
			methodNotAllowed(response, http.MethodDelete)
			return
		}
		result, err := s.contacts.CancelRequest(request.Context(), principal, requestID)
		if err != nil {
			s.writeContactsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	var result contacts.ContactRequest
	switch parts[1] {
	case "accept":
		result, err = s.contacts.AcceptRequest(request.Context(), principal, requestID)
	case "reject":
		result, err = s.contacts.RejectRequest(request.Context(), principal, requestID)
	default:
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if err != nil {
		s.writeContactsError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleContacts(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, ok := s.requireContactsPrincipal(response, request)
	if !ok {
		return
	}
	page, pageSize, ok := parsePageQuery(response, request)
	if !ok {
		return
	}
	result, err := s.contacts.ListContacts(request.Context(), principal, page, pageSize)
	if err != nil {
		s.writeContactsError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleContactByUserID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireContactsPrincipal(response, request)
	if !ok {
		return
	}
	contactUserID, ok := parseUUIDPathSuffix(response, request.URL.Path, "/api/v1/contacts/", "userId")
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodPatch:
		if !requireJSON(response, request) {
			return
		}
		var input contacts.UpdateContactInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		if input.Remark == nil && input.IsStarred == nil && input.Tags == nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "At least one contact field must be provided")
			return
		}
		result, err := s.contacts.UpdateContact(request.Context(), principal, contactUserID, input)
		if err != nil {
			s.writeContactsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	case http.MethodDelete:
		if err := s.contacts.DeleteContact(request.Context(), principal, contactUserID); err != nil {
			s.writeContactsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"deleted": true})
	default:
		methodNotAllowed(response, http.MethodPatch, http.MethodDelete)
	}
}

func (s *server) handleBlocks(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireContactsPrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodGet:
		page, pageSize, ok := parsePageQuery(response, request)
		if !ok {
			return
		}
		result, err := s.contacts.ListBlocks(request.Context(), principal, page, pageSize)
		if err != nil {
			s.writeContactsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	case http.MethodPost:
		if !requireJSON(response, request) {
			return
		}
		var input blockUserRequest
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		blockedUserID, err := uuid.Parse(strings.TrimSpace(input.UserID))
		if err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "userId must be a UUID")
			return
		}
		result, err := s.contacts.BlockUser(request.Context(), principal, blockedUserID)
		if err != nil {
			s.writeContactsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusCreated, result)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPost)
	}
}

func (s *server) handleBlockByUserID(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodDelete {
		methodNotAllowed(response, http.MethodDelete)
		return
	}
	principal, ok := s.requireContactsPrincipal(response, request)
	if !ok {
		return
	}
	blockedUserID, ok := parseUUIDPathSuffix(response, request.URL.Path, "/api/v1/blocks/", "userId")
	if !ok {
		return
	}
	if err := s.contacts.UnblockUser(request.Context(), principal, blockedUserID); err != nil {
		s.writeContactsError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"deleted": true})
}

func (s *server) requireContactsPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.contacts == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "CONTACTS_SERVICE_UNAVAILABLE", "Contacts service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) writeContactsError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, contacts.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested relationship resource was not found")
	case errors.Is(err, contacts.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "FORBIDDEN", "Operation is not allowed")
	case errors.Is(err, contacts.ErrBlocked):
		writeAPIError(response, http.StatusConflict, "RELATIONSHIP_UNAVAILABLE", "Relationship action is unavailable")
	case errors.Is(err, contacts.ErrAlreadyContact):
		writeAPIError(response, http.StatusConflict, "ALREADY_CONTACT", "Users are already contacts")
	case errors.Is(err, contacts.ErrRequestConflict), errors.Is(err, contacts.ErrInvalidState):
		writeAPIError(response, http.StatusConflict, "RELATIONSHIP_STATE_CONFLICT", "Relationship state does not allow this action")
	case errors.Is(err, contacts.ErrRateLimited):
		response.Header().Set("Retry-After", "60")
		writeAPIError(response, http.StatusTooManyRequests, "CONTACTS_RATE_LIMITED", "Too many relationship requests; try again later")
	case errors.Is(err, contacts.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "CONTACTS_SERVICE_UNAVAILABLE", "Contacts service is not configured")
	default:
		if isContactsValidationError(err) {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		s.logger.Error("contacts request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "CONTACTS_INTERNAL_ERROR", "Contacts request failed")
	}
}

func isContactsValidationError(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	for _, fragment := range []string{"handle", "contact request message", "contact remark", "contact tag", "direction"} {
		if strings.Contains(text, fragment) {
			return true
		}
	}
	return false
}

func parseUUIDPathSuffix(response http.ResponseWriter, path, prefix, field string) (uuid.UUID, bool) {
	raw := strings.Trim(strings.TrimPrefix(path, prefix), "/")
	if raw == "" || strings.Contains(raw, "/") {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return uuid.Nil, false
	}
	value, err := uuid.Parse(raw)
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", field+" must be a UUID")
		return uuid.Nil, false
	}
	return value, true
}

func parsePageQuery(response http.ResponseWriter, request *http.Request) (int, int, bool) {
	page, pageSize := 1, 50
	var err error
	if raw := strings.TrimSpace(request.URL.Query().Get("page")); raw != "" {
		page, err = strconv.Atoi(raw)
		if err != nil || page < 1 {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "page must be a positive integer")
			return 0, 0, false
		}
	}
	if raw := strings.TrimSpace(request.URL.Query().Get("pageSize")); raw != "" {
		pageSize, err = strconv.Atoi(raw)
		if err != nil || pageSize < 1 || pageSize > 100 {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "pageSize must be between 1 and 100")
			return 0, 0, false
		}
	}
	return page, pageSize, true
}
