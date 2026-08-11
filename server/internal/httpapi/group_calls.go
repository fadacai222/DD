package httpapi

import (
	"context"
	"errors"
	"net/http"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/groups"
	"github.com/google/uuid"
)

type groupCallsService interface {
	StartGroupCall(ctx context.Context, principal account.Principal, groupID uuid.UUID, kind string) (groups.GroupCallJoin, []uuid.UUID, error)
	JoinGroupCall(ctx context.Context, principal account.Principal, groupID, callID uuid.UUID) (groups.GroupCallJoin, []uuid.UUID, error)
	LeaveGroupCall(ctx context.Context, principal account.Principal, groupID, callID uuid.UUID) (groups.GroupCall, []uuid.UUID, error)
	GetActiveGroupCall(ctx context.Context, principal account.Principal, groupID uuid.UUID) (groups.GroupCall, error)
}

type startGroupCallRequest struct {
	Kind string `json:"kind"`
}

func (s *server) handleGroupCalls(
	response http.ResponseWriter,
	request *http.Request,
	principal account.Principal,
	parts []string,
) {
	service, ok := s.groups.(groupCallsService)
	if !ok {
		writeAPIError(response, http.StatusServiceUnavailable, "GROUP_CALLS_UNAVAILABLE", "Group calls are not configured")
		return
	}
	if len(parts) < 2 {
		writeAPIError(response, http.StatusBadRequest, "INVALID_GROUP_REQUEST", "Invalid group call route")
		return
	}
	groupID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_GROUP_REQUEST", "groupId must be a UUID")
		return
	}

	if len(parts) == 2 {
		if request.Method != http.MethodPost {
			methodNotAllowed(response, http.MethodPost)
			return
		}
		if !requireJSON(response, request) {
			return
		}
		var input startGroupCallRequest
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_GROUP_CALL_REQUEST", err.Error())
			return
		}
		joined, recipients, err := service.StartGroupCall(request.Context(), principal, groupID, input.Kind)
		if err != nil {
			s.writeGroupCallError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "group-call-started")
		writeSuccess(response, http.StatusCreated, joined)
		return
	}

	if len(parts) == 3 && parts[2] == "active" {
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		call, err := service.GetActiveGroupCall(request.Context(), principal, groupID)
		if err != nil {
			s.writeGroupCallError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, call)
		return
	}

	if len(parts) == 4 {
		if request.Method != http.MethodPost {
			methodNotAllowed(response, http.MethodPost)
			return
		}
		callID, err := uuid.Parse(parts[2])
		if err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_GROUP_CALL_REQUEST", "callId must be a UUID")
			return
		}
		switch parts[3] {
		case "join":
			joined, recipients, err := service.JoinGroupCall(request.Context(), principal, groupID, callID)
			if err != nil {
				s.writeGroupCallError(response, request, err)
				return
			}
			s.publishEventAvailable(recipients, "group-call-participants-changed")
			writeSuccess(response, http.StatusOK, joined)
		case "leave":
			call, recipients, err := service.LeaveGroupCall(request.Context(), principal, groupID, callID)
			if err != nil {
				s.writeGroupCallError(response, request, err)
				return
			}
			s.publishEventAvailable(recipients, "group-call-participants-changed")
			writeSuccess(response, http.StatusOK, call)
		default:
			writeAPIError(response, http.StatusNotFound, "GROUP_CALL_ROUTE_NOT_FOUND", "Group call route not found")
		}
		return
	}

	writeAPIError(response, http.StatusNotFound, "GROUP_CALL_ROUTE_NOT_FOUND", "Group call route not found")
}

func (s *server) writeGroupCallError(
	response http.ResponseWriter,
	request *http.Request,
	err error,
) {
	switch {
	case errors.Is(err, groups.ErrGroupCallConflict):
		writeAPIError(response, http.StatusConflict, "GROUP_CALL_CONFLICT", "A different group call is already active")
	case errors.Is(err, groups.ErrGroupCallFull):
		writeAPIError(response, http.StatusConflict, "GROUP_CALL_FULL", "Group call participant limit reached")
	case errors.Is(err, groups.ErrGroupCallUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "GROUP_CALL_UNAVAILABLE", "Group call media service is unavailable")
	case errors.Is(err, groups.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "GROUP_CALL_FORBIDDEN", "Active group membership is required")
	case errors.Is(err, groups.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "GROUP_CALL_NOT_FOUND", "Active group call was not found")
	default:
		s.writeGroupsError(response, request, err)
	}
}
