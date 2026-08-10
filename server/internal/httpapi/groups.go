package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/groups"
	"github.com/google/uuid"
)

type GroupsService interface {
	Create(ctx context.Context, principal account.Principal, input groups.CreateGroupInput) (groups.Group, error)
	Get(ctx context.Context, principal account.Principal, groupID uuid.UUID) (groups.Group, error)
	Update(ctx context.Context, principal account.Principal, groupID uuid.UUID, input groups.UpdateGroupInput) (groups.Group, error)
	ActiveMemberIDs(ctx context.Context, groupID uuid.UUID) ([]uuid.UUID, error)
	ListMembers(ctx context.Context, principal account.Principal, groupID uuid.UUID) ([]groups.GroupMember, error)
	InviteMembers(ctx context.Context, principal account.Principal, groupID uuid.UUID, input groups.InviteMembersInput) ([]groups.GroupMember, error)
	RemoveMember(ctx context.Context, principal account.Principal, groupID, targetUserID uuid.UUID) error
	UpdateMember(ctx context.Context, principal account.Principal, groupID, targetUserID uuid.UUID, input groups.UpdateMemberInput) (groups.GroupMember, error)
	Leave(ctx context.Context, principal account.Principal, groupID uuid.UUID) error
	TransferOwnership(ctx context.Context, principal account.Principal, groupID uuid.UUID, input groups.TransferOwnershipInput) (groups.Group, error)
	Dissolve(ctx context.Context, principal account.Principal, groupID uuid.UUID) error
	CreateJoinRequest(ctx context.Context, principal account.Principal, groupID uuid.UUID, input groups.CreateJoinRequestInput) (groups.JoinRequest, error)
	ListJoinRequests(ctx context.Context, principal account.Principal, groupID uuid.UUID) ([]groups.JoinRequest, error)
	ResolveJoinRequest(ctx context.Context, principal account.Principal, groupID, requestID uuid.UUID, approve bool) (groups.JoinRequest, error)
}

func (s *server) handleGroups(response http.ResponseWriter, request *http.Request) {
	if request.URL.Path != "/api/v1/groups" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	principal, ok := s.requireGroupsPrincipal(response, request)
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
	var input groups.CreateGroupInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.groups.Create(request.Context(), principal, input)
	if err != nil {
		s.writeGroupsError(response, request, err)
		return
	}
	groupID := uuid.MustParse(result.ID)
	s.publishGroupEventAvailable(request.Context(), groupID, nil, "group-created")
	writeSuccess(response, http.StatusCreated, result)
}

func (s *server) handleGroupByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireGroupsPrincipal(response, request)
	if !ok {
		return
	}
	raw := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/groups/"), "/")
	parts := strings.Split(raw, "/")
	if len(parts) < 1 || len(parts) > 4 || strings.TrimSpace(parts[0]) == "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	groupID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "groupId must be a UUID")
		return
	}

	if len(parts) == 1 {
		s.handleGroupRoot(response, request, principal, groupID)
		return
	}
	switch parts[1] {
	case "members":
		s.handleGroupMembers(response, request, principal, groupID, parts[2:])
	case "leave":
		if len(parts) != 2 {
			writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
			return
		}
		if request.Method != http.MethodPost {
			methodNotAllowed(response, http.MethodPost)
			return
		}
		recipients, _ := s.groups.ActiveMemberIDs(request.Context(), groupID)
		if err := s.groups.Leave(request.Context(), principal, groupID); err != nil {
			s.writeGroupsError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "group-left")
		writeSuccess(response, http.StatusOK, map[string]any{"left": true})
	case "transfer":
		if len(parts) != 2 {
			writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
			return
		}
		if request.Method != http.MethodPost {
			methodNotAllowed(response, http.MethodPost)
			return
		}
		if !requireJSON(response, request) {
			return
		}
		var input groups.TransferOwnershipInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		result, err := s.groups.TransferOwnership(request.Context(), principal, groupID, input)
		if err != nil {
			s.writeGroupsError(response, request, err)
			return
		}
		s.publishGroupEventAvailable(request.Context(), groupID, nil, "group-owner-transferred")
		writeSuccess(response, http.StatusOK, result)
	case "join-requests":
		s.handleGroupJoinRequests(response, request, principal, groupID, parts[2:])
	default:
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
	}
}

func (s *server) handleGroupRoot(response http.ResponseWriter, request *http.Request, principal account.Principal, groupID uuid.UUID) {
	switch request.Method {
	case http.MethodGet:
		result, err := s.groups.Get(request.Context(), principal, groupID)
		if err != nil {
			s.writeGroupsError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	case http.MethodPatch:
		if !requireJSON(response, request) {
			return
		}
		var input groups.UpdateGroupInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		result, err := s.groups.Update(request.Context(), principal, groupID, input)
		if err != nil {
			s.writeGroupsError(response, request, err)
			return
		}
		s.publishGroupEventAvailable(request.Context(), groupID, nil, "group-updated")
		writeSuccess(response, http.StatusOK, result)
	case http.MethodDelete:
		recipients, _ := s.groups.ActiveMemberIDs(request.Context(), groupID)
		if err := s.groups.Dissolve(request.Context(), principal, groupID); err != nil {
			s.writeGroupsError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "group-dissolved")
		writeSuccess(response, http.StatusOK, map[string]any{"dissolved": true})
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPatch, http.MethodDelete)
	}
}

func (s *server) handleGroupMembers(response http.ResponseWriter, request *http.Request, principal account.Principal, groupID uuid.UUID, tail []string) {
	if len(tail) == 0 {
		switch request.Method {
		case http.MethodGet:
			items, err := s.groups.ListMembers(request.Context(), principal, groupID)
			if err != nil {
				s.writeGroupsError(response, request, err)
				return
			}
			writeSuccess(response, http.StatusOK, map[string]any{"items": items})
		case http.MethodPost:
			if !requireJSON(response, request) {
				return
			}
			var input groups.InviteMembersInput
			if err := decodeSingleJSON(response, request, &input); err != nil {
				writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
				return
			}
			items, err := s.groups.InviteMembers(request.Context(), principal, groupID, input)
			if err != nil {
				s.writeGroupsError(response, request, err)
				return
			}
			s.publishGroupEventAvailable(request.Context(), groupID, nil, "group-members-added")
			writeSuccess(response, http.StatusOK, map[string]any{"items": items})
		default:
			methodNotAllowed(response, http.MethodGet, http.MethodPost)
		}
		return
	}
	if len(tail) != 1 {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	targetUserID, err := uuid.Parse(tail[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "userId must be a UUID")
		return
	}
	switch request.Method {
	case http.MethodPatch:
		if !requireJSON(response, request) {
			return
		}
		var input groups.UpdateMemberInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		result, err := s.groups.UpdateMember(request.Context(), principal, groupID, targetUserID, input)
		if err != nil {
			s.writeGroupsError(response, request, err)
			return
		}
		s.publishGroupEventAvailable(request.Context(), groupID, nil, "group-member-updated")
		writeSuccess(response, http.StatusOK, result)
	case http.MethodDelete:
		recipients, _ := s.groups.ActiveMemberIDs(request.Context(), groupID)
		if err := s.groups.RemoveMember(request.Context(), principal, groupID, targetUserID); err != nil {
			s.writeGroupsError(response, request, err)
			return
		}
		s.publishEventAvailable(recipients, "group-member-removed")
		writeSuccess(response, http.StatusOK, map[string]any{"removed": true})
	default:
		methodNotAllowed(response, http.MethodPatch, http.MethodDelete)
	}
}

func (s *server) handleGroupJoinRequests(response http.ResponseWriter, request *http.Request, principal account.Principal, groupID uuid.UUID, tail []string) {
	if len(tail) == 0 {
		switch request.Method {
		case http.MethodGet:
			items, err := s.groups.ListJoinRequests(request.Context(), principal, groupID)
			if err != nil {
				s.writeGroupsError(response, request, err)
				return
			}
			writeSuccess(response, http.StatusOK, map[string]any{"items": items})
		case http.MethodPost:
			if !requireJSON(response, request) {
				return
			}
			var input groups.CreateJoinRequestInput
			if err := decodeSingleJSON(response, request, &input); err != nil {
				writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
				return
			}
			result, err := s.groups.CreateJoinRequest(request.Context(), principal, groupID, input)
			if err != nil {
				s.writeGroupsError(response, request, err)
				return
			}
			s.publishGroupEventAvailable(request.Context(), groupID, nil, "group-join-request")
			writeSuccess(response, http.StatusCreated, result)
		default:
			methodNotAllowed(response, http.MethodGet, http.MethodPost)
		}
		return
	}
	if len(tail) != 2 || request.Method != http.MethodPost {
		if request.Method != http.MethodPost {
			methodNotAllowed(response, http.MethodPost)
			return
		}
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	requestID, err := uuid.Parse(tail[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "requestId must be a UUID")
		return
	}
	approve := false
	switch tail[1] {
	case "approve":
		approve = true
	case "reject":
	default:
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	result, err := s.groups.ResolveJoinRequest(request.Context(), principal, groupID, requestID, approve)
	if err != nil {
		s.writeGroupsError(response, request, err)
		return
	}
	extra := make([]uuid.UUID, 0, 1)
	if requesterID, parseErr := uuid.Parse(result.Requester.ID); parseErr == nil {
		extra = append(extra, requesterID)
	}
	s.publishGroupEventAvailable(request.Context(), groupID, extra, "group-join-resolved")
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) requireGroupsPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.groups == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "GROUPS_SERVICE_UNAVAILABLE", "Groups service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) publishGroupEventAvailable(ctx context.Context, groupID uuid.UUID, extra []uuid.UUID, reason string) {
	userIDs, err := s.groups.ActiveMemberIDs(ctx, groupID)
	if err != nil {
		s.logger.Warn("group realtime recipients unavailable", "groupId", groupID.String(), "error", err)
	}
	userIDs = append(userIDs, extra...)
	s.publishEventAvailable(userIDs, reason)
}

func (s *server) writeGroupsError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, groups.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_GROUP_REQUEST", "Group input is invalid")
	case errors.Is(err, groups.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "GROUP_NOT_FOUND", "Group resource was not found")
	case errors.Is(err, groups.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "GROUP_FORBIDDEN", "Group operation is not allowed")
	case errors.Is(err, groups.ErrAlreadyMember):
		writeAPIError(response, http.StatusConflict, "GROUP_ALREADY_MEMBER", "User is already an active group member")
	case errors.Is(err, groups.ErrMemberLimit):
		writeAPIError(response, http.StatusConflict, "GROUP_MEMBER_LIMIT", "Group member limit reached")
	case errors.Is(err, groups.ErrConflict):
		writeAPIError(response, http.StatusConflict, "GROUP_STATE_CONFLICT", "Group state does not allow this operation")
	case errors.Is(err, groups.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "GROUPS_SERVICE_UNAVAILABLE", "Groups service is not configured")
	default:
		s.logger.Error("groups request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "GROUPS_INTERNAL_ERROR", "Groups request failed")
	}
}
