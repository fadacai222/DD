package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/contacts"
	"github.com/google/uuid"
)

type fakeContactsService struct {
	searchResult            contacts.SearchResult
	searchErr               error
	acceptErr               error
	lastHandle              string
	lastUserID              uuid.UUID
	mentionItems            []contacts.MentionSuggestion
	mentionErr              error
	lastMentionQuery        string
	lastMentionConversation *uuid.UUID
	lastMentionLimit        int
}

func (fake *fakeContactsService) SearchByHandle(_ context.Context, _ account.Principal, handle string) (contacts.SearchResult, error) {
	fake.lastHandle = handle
	return fake.searchResult, fake.searchErr
}
func (fake *fakeContactsService) GetUserByID(_ context.Context, _ account.Principal, userID uuid.UUID) (contacts.SearchResult, error) {
	fake.lastUserID = userID
	return fake.searchResult, fake.searchErr
}
func (fake *fakeContactsService) SuggestMentions(_ context.Context, _ account.Principal, query string, conversationID *uuid.UUID, limit int) ([]contacts.MentionSuggestion, error) {
	fake.lastMentionQuery = query
	fake.lastMentionConversation = conversationID
	fake.lastMentionLimit = limit
	return fake.mentionItems, fake.mentionErr
}
func (fake *fakeContactsService) SendRequest(_ context.Context, _ account.Principal, _ contacts.SendRequestInput) (contacts.ContactRequest, error) {
	return contacts.ContactRequest{}, nil
}
func (fake *fakeContactsService) AcceptRequest(_ context.Context, _ account.Principal, _ uuid.UUID) (contacts.ContactRequest, error) {
	return contacts.ContactRequest{}, fake.acceptErr
}
func (fake *fakeContactsService) RejectRequest(_ context.Context, _ account.Principal, _ uuid.UUID) (contacts.ContactRequest, error) {
	return contacts.ContactRequest{}, nil
}
func (fake *fakeContactsService) CancelRequest(_ context.Context, _ account.Principal, _ uuid.UUID) (contacts.ContactRequest, error) {
	return contacts.ContactRequest{}, nil
}
func (fake *fakeContactsService) ListRequests(_ context.Context, _ account.Principal, _ string, page, pageSize int) (contacts.Page[contacts.ContactRequest], error) {
	return contacts.Page[contacts.ContactRequest]{Items: []contacts.ContactRequest{}, Page: page, PageSize: pageSize}, nil
}
func (fake *fakeContactsService) ListContacts(_ context.Context, _ account.Principal, page, pageSize int) (contacts.Page[contacts.Contact], error) {
	return contacts.Page[contacts.Contact]{Items: []contacts.Contact{}, Page: page, PageSize: pageSize}, nil
}
func (fake *fakeContactsService) AddContact(_ context.Context, _ account.Principal, _ uuid.UUID) (contacts.Contact, error) {
	return contacts.Contact{}, nil
}
func (fake *fakeContactsService) UpdateContact(_ context.Context, _ account.Principal, _ uuid.UUID, _ contacts.UpdateContactInput) (contacts.Contact, error) {
	return contacts.Contact{}, nil
}
func (fake *fakeContactsService) DeleteContact(_ context.Context, _ account.Principal, _ uuid.UUID) error {
	return nil
}
func (fake *fakeContactsService) BlockUser(_ context.Context, _ account.Principal, _ uuid.UUID) (contacts.BlockedUser, error) {
	return contacts.BlockedUser{}, nil
}
func (fake *fakeContactsService) UnblockUser(_ context.Context, _ account.Principal, _ uuid.UUID) error {
	return nil
}
func (fake *fakeContactsService) ListBlocks(_ context.Context, _ account.Principal, page, pageSize int) (contacts.Page[contacts.BlockedUser], error) {
	return contacts.Page[contacts.BlockedUser]{Items: []contacts.BlockedUser{}, Page: page, PageSize: pageSize}, nil
}

func TestContactsSearchRequiresBearerToken(t *testing.T) {
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: &fakeContactsService{}})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/users/by-handle/bob_01", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || !strings.Contains(response.Body.String(), `"code":"UNAUTHORIZED"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestContactsExactSearchReturnsPublicProfileWithoutEmail(t *testing.T) {
	fake := &fakeContactsService{searchResult: contacts.SearchResult{
		User: contacts.PublicUser{
			ID: uuid.NewString(), Handle: "bob_01", DisplayName: "Bob", Bio: "bio",
		},
		Relationship: "NONE",
	}}
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: fake})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/users/by-handle/bob_01", nil)
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.lastHandle != "bob_01" || strings.Contains(strings.ToLower(response.Body.String()), "email") {
		t.Fatalf("handle=%q body=%s", fake.lastHandle, response.Body.String())
	}
}

func TestMentionSuggestionsRequireAuthAndForwardBoundedQuery(t *testing.T) {
	conversationID := uuid.New()
	fake := &fakeContactsService{mentionItems: []contacts.MentionSuggestion{{
		User:         contacts.PublicUser{ID: uuid.NewString(), Handle: "alice", DisplayName: "Alice"},
		Relationship: "CONTACT",
	}}}
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: fake})

	unauthorized := httptest.NewRequest(http.MethodGet, "/api/v1/users/mention-suggestions?q=al&limit=8", nil)
	unauthorizedResponse := httptest.NewRecorder()
	handler.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d", unauthorizedResponse.Code)
	}

	request := httptest.NewRequest(
		http.MethodGet,
		"/api/v1/users/mention-suggestions?q=al&limit=7&conversationId="+conversationID.String(),
		nil,
	)
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.lastMentionQuery != "al" || fake.lastMentionLimit != 7 || fake.lastMentionConversation == nil || *fake.lastMentionConversation != conversationID {
		t.Fatalf("query=%q limit=%d conversation=%v", fake.lastMentionQuery, fake.lastMentionLimit, fake.lastMentionConversation)
	}
	if !strings.Contains(response.Body.String(), `"handle":"alice"`) {
		t.Fatalf("body=%s", response.Body.String())
	}
}

func TestMentionSuggestionErrorsStayExplicit(t *testing.T) {
	for _, test := range []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{name: "invalid", err: contacts.ErrInvalidMentionQuery, wantStatus: http.StatusBadRequest, wantCode: "INVALID_MENTION_QUERY"},
		{name: "rate limited", err: contacts.ErrRateLimited, wantStatus: http.StatusTooManyRequests, wantCode: "CONTACTS_RATE_LIMITED"},
	} {
		t.Run(test.name, func(t *testing.T) {
			fake := &fakeContactsService{mentionErr: test.err}
			handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: fake})
			request := httptest.NewRequest(http.MethodGet, "/api/v1/users/mention-suggestions?q=al", nil)
			request.Header.Set("Authorization", "Bearer test")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != test.wantStatus || !strings.Contains(response.Body.String(), `"code":"`+test.wantCode+`"`) {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestStableUserProfileReturnsPublicProfileByUserID(t *testing.T) {
	userID := uuid.New()
	fake := &fakeContactsService{searchResult: contacts.SearchResult{
		User:         contacts.PublicUser{ID: userID.String(), Handle: "bob_01", DisplayName: "Bob", Bio: "bio"},
		Relationship: "CONTACT",
	}}
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: fake})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/users/"+userID.String(), nil)
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.lastUserID != userID || strings.Contains(strings.ToLower(response.Body.String()), "email") {
		t.Fatalf("userID=%s body=%s", fake.lastUserID, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"relationship":"CONTACT"`) {
		t.Fatalf("relationship missing: %s", response.Body.String())
	}
}

func TestContactsBlockedSearchIsIndistinguishableFromNotFound(t *testing.T) {
	fake := &fakeContactsService{searchErr: contacts.ErrNotFound}
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: fake})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/users/by-handle/blocked_01", nil)
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), `"code":"NOT_FOUND"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestContactRequestIDORReturnsForbidden(t *testing.T) {
	fake := &fakeContactsService{acceptErr: contacts.ErrForbidden}
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: fake})
	requestID := uuid.NewString()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/contact-requests/"+requestID+"/accept", nil)
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), `"code":"FORBIDDEN"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestContactsPageSizeRejectsUnboundedRequest(t *testing.T) {
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: &fakeContactsService{}})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/contacts?pageSize=1000", nil)
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestContactsMethodAllowHeaderListsSupportedMethods(t *testing.T) {
	handler := NewHandler(Config{AuthService: &fakeAuthService{}, ContactsService: &fakeContactsService{}})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/contacts/"+uuid.NewString(), strings.NewReader(`{}`))
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusMethodNotAllowed || response.Header().Get("Allow") != "PUT, PATCH, DELETE" {
		t.Fatalf("status=%d allow=%q body=%s", response.Code, response.Header().Get("Allow"), response.Body.String())
	}
}
