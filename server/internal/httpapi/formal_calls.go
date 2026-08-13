package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/calls"
	"github.com/google/uuid"
)

type CallsService interface {
	Create(ctx context.Context, principal account.Principal, input calls.CreateInput) (calls.Call, error)
	GetActive(ctx context.Context, principal account.Principal) (*calls.Call, error)
	ApplyAction(ctx context.Context, principal account.Principal, callID uuid.UUID, input calls.ActionInput) (calls.Call, error)
	AuthorizeToken(ctx context.Context, principal account.Principal, callID uuid.UUID) (calls.TokenAuthorization, error)
	Timeout(ctx context.Context, callID uuid.UUID) (calls.Call, bool, error)
}

func (s *server) handleFormalCalls(response http.ResponseWriter, request *http.Request) {
	if request.URL.Path != "/api/v1/calls" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	principal, ok := s.requireFormalCallsPrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input calls.CreateInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.formalCalls.Create(request.Context(), principal, input)
	if err != nil {
		s.writeFormalCallsError(response, request, err)
		return
	}
	s.publishCallAvailability(result, "call-created")
	s.scheduleFormalCallTimeout(result)
	writeSuccess(response, http.StatusCreated, result)
}

func (s *server) handleFormalActiveCall(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireFormalCallsPrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	result, err := s.formalCalls.GetActive(request.Context(), principal)
	if err != nil {
		s.writeFormalCallsError(response, request, err)
		return
	}
	if result == nil {
		response.WriteHeader(http.StatusNoContent)
		return
	}
	writeSuccess(response, http.StatusOK, *result)
}

func (s *server) handleFormalCallByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireFormalCallsPrincipal(response, request)
	if !ok {
		return
	}
	raw := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/calls/"), "/")
	parts := strings.Split(raw, "/")
	if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
		writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", "Call not found")
		return
	}
	callID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_ID", "callId must be a UUID")
		return
	}
	switch parts[1] {
	case "actions":
		s.handleFormalCallAction(response, request, principal, callID)
	case "token":
		s.handleFormalCallToken(response, request, principal, callID)
	default:
		writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", "Call not found")
	}
}

func (s *server) handleFormalCallAction(response http.ResponseWriter, request *http.Request, principal account.Principal, callID uuid.UUID) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input calls.ActionInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.formalCalls.ApplyAction(request.Context(), principal, callID, input)
	if err != nil {
		s.writeFormalCallsError(response, request, err)
		return
	}
	s.publishCallAvailability(result, "call-updated")
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleFormalCallToken(response http.ResponseWriter, request *http.Request, principal account.Principal, callID uuid.UUID) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	authorization, err := s.formalCalls.AuthorizeToken(request.Context(), principal, callID)
	if err != nil {
		s.writeFormalCallsError(response, request, err)
		return
	}
	s.issueCallToken(
		response,
		request,
		authorization.RoomName,
		authorization.ParticipantID,
		authorization.ParticipantName,
	)
}

func (s *server) requireFormalCallsPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.formalCalls == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "CALLS_SERVICE_UNAVAILABLE", "Calls service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) publishCallAvailability(call calls.Call, reason string) {
	userIDs := make([]uuid.UUID, 0, 2)
	if callerID, err := uuid.Parse(call.CallerIdentity); err == nil {
		userIDs = append(userIDs, callerID)
	}
	if calleeID, err := uuid.Parse(call.CalleeIdentity); err == nil {
		userIDs = append(userIDs, calleeID)
	}
	s.publishEventAvailable(userIDs, reason)
}

func (s *server) scheduleFormalCallTimeout(call calls.Call) {
	callID, err := uuid.Parse(call.ID)
	if err != nil || call.RingTimeoutSecond <= 0 || s.formalCalls == nil {
		return
	}
	time.AfterFunc(time.Duration(call.RingTimeoutSecond)*time.Second, func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		timedOut, changed, timeoutErr := s.formalCalls.Timeout(ctx, callID)
		if timeoutErr != nil {
			s.logger.Error("formal call timeout failed", "callId", call.ID, "error", timeoutErr)
			return
		}
		if changed {
			s.publishCallAvailability(timedOut, "call-timeout")
		}
	})
}

func (s *server) writeFormalCallsError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, calls.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_REQUEST", "Call request is invalid")
	case errors.Is(err, calls.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", "Call or participant was not found")
	case errors.Is(err, calls.ErrBlocked):
		writeAPIError(response, http.StatusForbidden, "CALL_BLOCKED", "Call is blocked by relationship policy")
	case errors.Is(err, calls.ErrContactRequired):
		writeAPIError(response, http.StatusForbidden, "CALL_CONTACT_REQUIRED", "Calls require the callee to be a contact")
	case errors.Is(err, calls.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "CALL_FORBIDDEN", "Call operation is not allowed")
	case errors.Is(err, calls.ErrBusy):
		writeAPIError(response, http.StatusConflict, "CALL_BUSY", "A participant already has an active call")
	case errors.Is(err, calls.ErrConflict):
		writeAPIError(response, http.StatusConflict, "INVALID_CALL_STATE", "Call state does not allow this operation")
	case errors.Is(err, calls.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "CALLS_SERVICE_UNAVAILABLE", "Calls service is not configured")
	default:
		s.logger.Error(
			"formal calls request failed",
			"requestId", response.Header().Get(requestIDHeader),
			"path", request.URL.Path,
			"error", err,
		)
		writeAPIError(response, http.StatusInternalServerError, "CALLS_INTERNAL_ERROR", "Calls request failed")
	}
}
