package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/moments"
	"github.com/google/uuid"
)

type fakeMomentsService struct {
	createdInput moments.CreateInput
	lastMomentID uuid.UUID
	lastLiked    *bool
	lastComment  moments.CommentInput
	recipients   []uuid.UUID
	item         moments.Moment
	err          error
}

func (f *fakeMomentsService) Create(_ context.Context, _ account.Principal, input moments.CreateInput) (moments.Moment, []uuid.UUID, error) {
	f.createdInput = input
	return f.item, f.recipients, f.err
}
func (f *fakeMomentsService) ListFeed(_ context.Context, _ account.Principal, _ *uuid.UUID, _ int) ([]moments.Moment, error) {
	return []moments.Moment{f.item}, f.err
}
func (f *fakeMomentsService) Get(_ context.Context, _ account.Principal, momentID uuid.UUID) (moments.Moment, error) {
	f.lastMomentID = momentID
	return f.item, f.err
}
func (f *fakeMomentsService) Delete(_ context.Context, _ account.Principal, momentID uuid.UUID) ([]uuid.UUID, error) {
	f.lastMomentID = momentID
	return f.recipients, f.err
}
func (f *fakeMomentsService) SetLike(_ context.Context, _ account.Principal, momentID uuid.UUID, liked bool) (moments.Moment, []uuid.UUID, error) {
	f.lastMomentID = momentID
	f.lastLiked = &liked
	return f.item, f.recipients, f.err
}
func (f *fakeMomentsService) AddComment(_ context.Context, _ account.Principal, momentID uuid.UUID, input moments.CommentInput) (moments.Moment, []uuid.UUID, error) {
	f.lastMomentID = momentID
	f.lastComment = input
	return f.item, f.recipients, f.err
}
func (f *fakeMomentsService) DeleteComment(_ context.Context, _ account.Principal, momentID, _ uuid.UUID) (moments.Moment, []uuid.UUID, error) {
	f.lastMomentID = momentID
	return f.item, f.recipients, f.err
}
func (f *fakeMomentsService) SetPreference(_ context.Context, _ account.Principal, targetID uuid.UUID, input moments.PreferenceInput) (moments.Preference, error) {
	return moments.Preference{Target: moments.UserPreview{ID: targetID.String()}, HideTarget: input.HideTarget, HideFromTarget: input.HideFromTarget, UpdatedAt: time.Now().UTC()}, f.err
}
func (f *fakeMomentsService) ListPreferences(_ context.Context, _ account.Principal) ([]moments.Preference, error) {
	return []moments.Preference{}, f.err
}

func TestMomentsCreateAndLikeUseAuthenticatedSurface(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	momentID := uuid.New()
	peerID := uuid.New()
	fake := &fakeMomentsService{
		item: moments.Moment{ID: momentID.String(), Author: moments.UserPreview{ID: principal.UserID.String(), Handle: "alice", DisplayName: "Alice"}, MediaIDs: []string{}, LikeUsers: []moments.UserPreview{}, Comments: []moments.Comment{}, CreatedAt: time.Now().UTC()},
		recipients: []uuid.UUID{principal.UserID, peerID},
	}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, MomentsService: fake})

	create := httptest.NewRequest(http.MethodPost, "/api/v1/moments", strings.NewReader(`{"text":"hello","visibility":"ALL_CONTACTS"}`))
	create.Header.Set("Authorization", "Bearer access")
	create.Header.Set("Content-Type", "application/json")
	createResponse := httptest.NewRecorder()
	handler.ServeHTTP(createResponse, create)
	if createResponse.Code != http.StatusCreated || fake.createdInput.Text != "hello" {
		t.Fatalf("create status=%d input=%+v body=%s", createResponse.Code, fake.createdInput, createResponse.Body.String())
	}

	like := httptest.NewRequest(http.MethodPut, "/api/v1/moments/"+momentID.String()+"/like", nil)
	like.Header.Set("Authorization", "Bearer access")
	likeResponse := httptest.NewRecorder()
	handler.ServeHTTP(likeResponse, like)
	if likeResponse.Code != http.StatusOK || fake.lastLiked == nil || !*fake.lastLiked {
		t.Fatalf("like status=%d liked=%v body=%s", likeResponse.Code, fake.lastLiked, likeResponse.Body.String())
	}

	unlike := httptest.NewRequest(http.MethodDelete, "/api/v1/moments/"+momentID.String()+"/like", nil)
	unlike.Header.Set("Authorization", "Bearer access")
	unlikeResponse := httptest.NewRecorder()
	handler.ServeHTTP(unlikeResponse, unlike)
	if unlikeResponse.Code != http.StatusOK || fake.lastLiked == nil || *fake.lastLiked {
		t.Fatalf("unlike status=%d liked=%v body=%s", unlikeResponse.Code, fake.lastLiked, unlikeResponse.Body.String())
	}
}

func TestMomentsPrivacyUses404StyleServiceBoundary(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	fake := &fakeMomentsService{err: moments.ErrNotFound}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, MomentsService: fake})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/moments/"+uuid.NewString(), nil)
	request.Header.Set("Authorization", "Bearer access")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), `"code":"MOMENT_NOT_FOUND"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestMomentsCommentsAndPreferencesRejectMalformedStableIDs(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, MomentsService: &fakeMomentsService{}})
	for _, target := range []string{
		"/api/v1/moments/not-a-uuid/comments",
		"/api/v1/moment-preferences/not-a-uuid",
	} {
		request := httptest.NewRequest(http.MethodPost, target, strings.NewReader(`{"text":"x"}`))
		if strings.Contains(target, "moment-preferences") {
			request.Method = http.MethodPatch
		}
		request.Header.Set("Authorization", "Bearer access")
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("target=%s status=%d body=%s", target, response.Code, response.Body.String())
		}
	}
}
