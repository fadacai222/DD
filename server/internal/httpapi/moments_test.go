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
	lastAuthorID *uuid.UUID
	recipients   []uuid.UUID
	item         moments.Moment
	profile      moments.Profile
	profileInput moments.UpdateProfileInput
	activity     moments.ActivitySummary
	markReadHits int
	err          error
}

func (f *fakeMomentsService) Create(_ context.Context, _ account.Principal, input moments.CreateInput) (moments.Moment, []uuid.UUID, error) {
	f.createdInput = input
	return f.item, f.recipients, f.err
}
func (f *fakeMomentsService) ListFeed(_ context.Context, _ account.Principal, _ *uuid.UUID, authorID *uuid.UUID, _ int) ([]moments.Moment, error) {
	f.lastAuthorID = authorID
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
func (f *fakeMomentsService) GetProfile(_ context.Context, _ account.Principal, _ uuid.UUID) (moments.Profile, error) {
	return f.profile, f.err
}
func (f *fakeMomentsService) UpdateProfile(_ context.Context, _ account.Principal, input moments.UpdateProfileInput) (moments.Profile, []uuid.UUID, error) {
	f.profileInput = input
	return f.profile, f.recipients, f.err
}
func (f *fakeMomentsService) GetActivitySummary(_ context.Context, _ account.Principal) (moments.ActivitySummary, error) {
	return f.activity, f.err
}
func (f *fakeMomentsService) MarkActivityRead(_ context.Context, _ account.Principal) (moments.ActivitySummary, error) {
	f.markReadHits++
	return moments.ActivitySummary{Items: []moments.ActivityItem{}}, f.err
}

func TestMomentsCreateAndLikeUseAuthenticatedSurface(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	momentID := uuid.New()
	peerID := uuid.New()
	fake := &fakeMomentsService{
		item:       moments.Moment{ID: momentID.String(), Author: moments.UserPreview{ID: principal.UserID.String(), Handle: "alice", DisplayName: "Alice"}, MediaIDs: []string{}, LikeUsers: []moments.UserPreview{}, Comments: []moments.Comment{}, CreatedAt: time.Now().UTC()},
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

func TestMomentsProfileGetAndPatchUseAuthenticatedOwner(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	coverID := uuid.New().String()
	fake := &fakeMomentsService{
		profile: moments.Profile{
			User:          moments.UserPreview{ID: principal.UserID.String(), Handle: "alice", DisplayName: "Alice"},
			CoverMediaID:  coverID,
			CoverRevision: 3,
			CanEdit:       true,
		},
		recipients: []uuid.UUID{principal.UserID},
	}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, MomentsService: fake})

	getRequest := httptest.NewRequest(http.MethodGet, "/api/v1/moment-profiles/"+principal.UserID.String(), nil)
	getRequest.Header.Set("Authorization", "Bearer access")
	getResponse := httptest.NewRecorder()
	handler.ServeHTTP(getResponse, getRequest)
	if getResponse.Code != http.StatusOK {
		t.Fatalf("get profile status=%d body=%s", getResponse.Code, getResponse.Body.String())
	}

	patchRequest := httptest.NewRequest(http.MethodPatch, "/api/v1/moment-profiles/"+principal.UserID.String(), strings.NewReader(`{"coverMediaId":"`+coverID+`"}`))
	patchRequest.Header.Set("Authorization", "Bearer access")
	patchRequest.Header.Set("Content-Type", "application/json")
	patchResponse := httptest.NewRecorder()
	handler.ServeHTTP(patchResponse, patchRequest)
	if patchResponse.Code != http.StatusOK || fake.profileInput.CoverMediaID != coverID {
		t.Fatalf("patch profile status=%d input=%+v body=%s", patchResponse.Code, fake.profileInput, patchResponse.Body.String())
	}

	peerID := uuid.New()
	forbidden := httptest.NewRequest(http.MethodPatch, "/api/v1/moment-profiles/"+peerID.String(), strings.NewReader(`{"coverMediaId":""}`))
	forbidden.Header.Set("Authorization", "Bearer access")
	forbidden.Header.Set("Content-Type", "application/json")
	forbiddenResponse := httptest.NewRecorder()
	handler.ServeHTTP(forbiddenResponse, forbidden)
	if forbiddenResponse.Code != http.StatusForbidden {
		t.Fatalf("peer profile patch status=%d body=%s", forbiddenResponse.Code, forbiddenResponse.Body.String())
	}
}

func TestMomentsFeedAcceptsOptionalAuthorFilter(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	authorID := uuid.New()
	fake := &fakeMomentsService{}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, MomentsService: fake})

	request := httptest.NewRequest(http.MethodGet, "/api/v1/moments?authorId="+authorID.String()+"&limit=12", nil)
	request.Header.Set("Authorization", "Bearer access")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.lastAuthorID == nil || *fake.lastAuthorID != authorID {
		t.Fatalf("author filter=%v want=%s", fake.lastAuthorID, authorID)
	}

	invalid := httptest.NewRequest(http.MethodGet, "/api/v1/moments?authorId=not-a-uuid", nil)
	invalid.Header.Set("Authorization", "Bearer access")
	invalidResponse := httptest.NewRecorder()
	handler.ServeHTTP(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusBadRequest || !strings.Contains(invalidResponse.Body.String(), `"code":"INVALID_MOMENT_REQUEST"`) {
		t.Fatalf("invalid author status=%d body=%s", invalidResponse.Code, invalidResponse.Body.String())
	}
}

func TestMomentActivitySummaryAndMarkReadUseAuthenticatedSurface(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	actorID := uuid.New()
	momentID := uuid.New()
	fake := &fakeMomentsService{activity: moments.ActivitySummary{
		UnreadCount: 123,
		Items: []moments.ActivityItem{{
			ID:          uuid.NewString(),
			Kind:        "COMMENT",
			Actor:       moments.UserPreview{ID: actorID.String(), Handle: "bob", DisplayName: "Bob"},
			MomentID:    momentID.String(),
			CommentText: "刚刚评论了你",
			CreatedAt:   time.Date(2026, 8, 12, 3, 58, 0, 0, time.UTC),
			Read:        false,
		}},
	}}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, MomentsService: fake})

	getRequest := httptest.NewRequest(http.MethodGet, "/api/v1/moment-activity", nil)
	getRequest.Header.Set("Authorization", "Bearer access")
	getResponse := httptest.NewRecorder()
	handler.ServeHTTP(getResponse, getRequest)
	if getResponse.Code != http.StatusOK ||
		!strings.Contains(getResponse.Body.String(), `"unreadCount":123`) ||
		!strings.Contains(getResponse.Body.String(), `"displayName":"Bob"`) ||
		!strings.Contains(getResponse.Body.String(), `"commentText":"刚刚评论了你"`) {
		t.Fatalf("get activity status=%d body=%s", getResponse.Code, getResponse.Body.String())
	}

	readRequest := httptest.NewRequest(http.MethodPost, "/api/v1/moment-activity/read", nil)
	readRequest.Header.Set("Authorization", "Bearer access")
	readResponse := httptest.NewRecorder()
	handler.ServeHTTP(readResponse, readRequest)
	if readResponse.Code != http.StatusOK || fake.markReadHits != 1 ||
		!strings.Contains(readResponse.Body.String(), `"unreadCount":0`) ||
		!strings.Contains(readResponse.Body.String(), `"items":[]`) {
		t.Fatalf("mark activity read status=%d hits=%d body=%s", readResponse.Code, fake.markReadHits, readResponse.Body.String())
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
