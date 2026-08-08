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
	searchResult contacts.SearchResult
	searchErr    error
	acceptErr    error
	lastHandle   string
}

func (fake *fakeContactsService) SearchByHandle(_ context.Context, _ account.Principal, handle string) (contacts.SearchResult, error) {
	fake.lastHandle = handle
	return fake.searchResult, fake.searchErr
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
	request := httptest.NewRequest(http.MethodPut, "/api/v1/contacts/"+uuid.NewString(), strings.NewReader(`{}`))
	request.Header.Set("Authorization", "Bearer test")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusMethodNotAllowed || response.Header().Get("Allow") != "PATCH, DELETE" {
		t.Fatalf("status=%d allow=%q body=%s", response.Code, response.Header().Get("Allow"), response.Body.String())
	}
}
