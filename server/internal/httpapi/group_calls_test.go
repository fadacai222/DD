package httpapi

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/groups"
	"github.com/google/uuid"
)

type groupCallRouteService struct {
	GroupsService
	started groups.GroupCallJoin
}

func (service *groupCallRouteService) StartGroupCall(context.Context, account.Principal, uuid.UUID, string) (groups.GroupCallJoin, []uuid.UUID, error) {
	return service.started, nil, nil
}

func (service *groupCallRouteService) JoinGroupCall(context.Context, account.Principal, uuid.UUID, uuid.UUID) (groups.GroupCallJoin, []uuid.UUID, error) {
	return groups.GroupCallJoin{}, nil, nil
}

func (service *groupCallRouteService) LeaveGroupCall(context.Context, account.Principal, uuid.UUID, uuid.UUID) (groups.GroupCall, []uuid.UUID, error) {
	return groups.GroupCall{}, nil, nil
}

func (service *groupCallRouteService) GetActiveGroupCall(context.Context, account.Principal, uuid.UUID) (groups.GroupCall, error) {
	return groups.GroupCall{}, nil
}

func TestGroupCallRouteReturnsCreatedWhenMediaConfigIsInjected(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &groupCallRouteService{started: groups.GroupCallJoin{
		Call:       groups.GroupCall{ID: uuid.NewString(), GroupID: uuid.NewString(), Kind: "VIDEO", Status: "ACTIVE"},
		LiveKitURL: "wss://media.example.com",
		Token:      "joined",
	}}
	s := &server{groups: service}
	groupID := uuid.New()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/groups/"+groupID.String()+"/calls", bytes.NewBufferString(`{"kind":"VIDEO"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	s.handleGroupCalls(response, request, principal, []string{groupID.String(), "calls"})

	if response.Code != http.StatusCreated {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	body := response.Body.String()
	if !bytes.Contains([]byte(body), []byte("wss://media.example.com")) || !bytes.Contains([]byte(body), []byte("joined")) {
		t.Fatalf("unexpected group call response: %s", body)
	}
}
