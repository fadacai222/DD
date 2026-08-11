package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/datarights"
	"github.com/google/uuid"
)

type fakeDataRightsService struct {
	export        datarights.ExportRequest
	download      datarights.ExportDownload
	deletion      datarights.DeletionRequest
	lastPrincipal account.Principal
	lastID        uuid.UUID
	lastKey       string
	lastPassword  string
	err           error
}

func (fake *fakeDataRightsService) RequestExport(_ context.Context, principal account.Principal, key string) (datarights.ExportRequest, error) {
	fake.lastPrincipal = principal
	fake.lastKey = key
	return fake.export, fake.err
}
func (fake *fakeDataRightsService) GetExport(_ context.Context, principal account.Principal, id uuid.UUID) (datarights.ExportRequest, error) {
	fake.lastPrincipal = principal
	fake.lastID = id
	return fake.export, fake.err
}
func (fake *fakeDataRightsService) CreateExportDownload(_ context.Context, principal account.Principal, id uuid.UUID) (datarights.ExportDownload, error) {
	fake.lastPrincipal = principal
	fake.lastID = id
	return fake.download, fake.err
}
func (fake *fakeDataRightsService) RequestDeletion(_ context.Context, principal account.Principal, input datarights.RequestDeletionInput, key string) (datarights.DeletionRequest, error) {
	fake.lastPrincipal = principal
	fake.lastKey = key
	fake.lastPassword = input.CurrentPassword
	return fake.deletion, fake.err
}
func (fake *fakeDataRightsService) GetDeletion(_ context.Context, principal account.Principal, id uuid.UUID) (datarights.DeletionRequest, error) {
	fake.lastPrincipal = principal
	fake.lastID = id
	return fake.deletion, fake.err
}
func (fake *fakeDataRightsService) CancelDeletion(_ context.Context, principal account.Principal, id uuid.UUID) (datarights.DeletionRequest, error) {
	fake.lastPrincipal = principal
	fake.lastID = id
	return fake.deletion, fake.err
}

func TestDataExportHTTPRequiresBearerAndIdempotency(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	fake := &fakeDataRightsService{export: datarights.ExportRequest{ID: uuid.NewString(), Status: datarights.ExportQueued, RequestedAt: time.Now().UTC(), Retryable: true}}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, DataRightsService: fake})

	unauthorized := httptest.NewRequest(http.MethodPost, "/api/v1/data-rights/exports", nil)
	unauthorizedResponse := httptest.NewRecorder()
	handler.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d body=%s", unauthorizedResponse.Code, unauthorizedResponse.Body.String())
	}

	missingKey := httptest.NewRequest(http.MethodPost, "/api/v1/data-rights/exports", nil)
	missingKey.Header.Set("Authorization", "Bearer access")
	missingKeyResponse := httptest.NewRecorder()
	handler.ServeHTTP(missingKeyResponse, missingKey)
	if missingKeyResponse.Code != http.StatusBadRequest || !strings.Contains(missingKeyResponse.Body.String(), "IDEMPOTENCY_KEY_REQUIRED") {
		t.Fatalf("missing key status=%d body=%s", missingKeyResponse.Code, missingKeyResponse.Body.String())
	}

	request := httptest.NewRequest(http.MethodPost, "/api/v1/data-rights/exports", nil)
	request.Header.Set("Authorization", "Bearer access")
	request.Header.Set("Idempotency-Key", "export-http-test")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusAccepted || fake.lastKey != "export-http-test" || fake.lastPrincipal != principal {
		t.Fatalf("request status=%d key=%q principal=%+v body=%s", response.Code, fake.lastKey, fake.lastPrincipal, response.Body.String())
	}
}

func TestDataExportStatusAndDownloadAuthorization(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	requestID := uuid.New()
	fake := &fakeDataRightsService{
		export:   datarights.ExportRequest{ID: requestID.String(), Status: datarights.ExportCompleted, RequestedAt: time.Now().UTC()},
		download: datarights.ExportDownload{DownloadURL: "https://private.invalid/object?sig=short", ExpiresAt: time.Now().UTC().Add(5 * time.Minute), FileName: "export.json.gz", SHA256: strings.Repeat("a", 64), SizeBytes: 123},
	}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, DataRightsService: fake})

	statusRequest := httptest.NewRequest(http.MethodGet, "/api/v1/data-rights/exports/"+requestID.String(), nil)
	statusRequest.Header.Set("Authorization", "Bearer access")
	statusResponse := httptest.NewRecorder()
	handler.ServeHTTP(statusResponse, statusRequest)
	if statusResponse.Code != http.StatusOK || fake.lastID != requestID {
		t.Fatalf("status code=%d id=%s body=%s", statusResponse.Code, fake.lastID, statusResponse.Body.String())
	}

	unauthorizedDownload := httptest.NewRequest(http.MethodPost, "/api/v1/data-rights/exports/"+requestID.String()+"/download", nil)
	unauthorizedDownloadResponse := httptest.NewRecorder()
	handler.ServeHTTP(unauthorizedDownloadResponse, unauthorizedDownload)
	if unauthorizedDownloadResponse.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized download=%d body=%s", unauthorizedDownloadResponse.Code, unauthorizedDownloadResponse.Body.String())
	}

	downloadRequest := httptest.NewRequest(http.MethodPost, "/api/v1/data-rights/exports/"+requestID.String()+"/download", nil)
	downloadRequest.Header.Set("Authorization", "Bearer access")
	downloadResponse := httptest.NewRecorder()
	handler.ServeHTTP(downloadResponse, downloadRequest)
	if downloadResponse.Code != http.StatusOK || downloadResponse.Header().Get("Cache-Control") != "no-store" || !strings.Contains(downloadResponse.Body.String(), "sig=short") {
		t.Fatalf("download status=%d cache=%q body=%s", downloadResponse.Code, downloadResponse.Header().Get("Cache-Control"), downloadResponse.Body.String())
	}
}

func TestAccountDeletionHTTPRequiresSecondaryAuthenticationAndIdempotency(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	requestID := uuid.New()
	fake := &fakeDataRightsService{deletion: datarights.DeletionRequest{ID: requestID.String(), Status: datarights.DeletionCoolingOff, RequestedAt: time.Now().UTC(), CoolingOffUntil: time.Now().UTC().Add(7 * 24 * time.Hour), Retryable: true}}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, DataRightsService: fake})

	request := httptest.NewRequest(http.MethodPost, "/api/v1/data-rights/account-deletion", strings.NewReader(`{"currentPassword":"correct password"}`))
	request.Header.Set("Authorization", "Bearer access")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Idempotency-Key", "delete-http-test")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusAccepted || fake.lastPassword != "correct password" || fake.lastKey != "delete-http-test" {
		t.Fatalf("request deletion status=%d password=%q key=%q body=%s", response.Code, fake.lastPassword, fake.lastKey, response.Body.String())
	}

	cancel := httptest.NewRequest(http.MethodPost, "/api/v1/data-rights/account-deletion/"+requestID.String()+"/cancel", nil)
	cancel.Header.Set("Authorization", "Bearer access")
	cancelResponse := httptest.NewRecorder()
	handler.ServeHTTP(cancelResponse, cancel)
	if cancelResponse.Code != http.StatusOK || fake.lastID != requestID {
		t.Fatalf("cancel status=%d id=%s body=%s", cancelResponse.Code, fake.lastID, cancelResponse.Body.String())
	}
}

func TestDataRightsErrorsUseStableMachineCodes(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	requestID := uuid.New()
	cases := []struct {
		name string
		err  error
		want int
		code string
	}{
		{name: "idor-not-found", err: datarights.ErrNotFound, want: http.StatusNotFound, code: "DATA_RIGHTS_REQUEST_NOT_FOUND"},
		{name: "download-not-ready", err: datarights.ErrNotReady, want: http.StatusConflict, code: "EXPORT_NOT_READY"},
		{name: "expired", err: datarights.ErrExpired, want: http.StatusGone, code: "EXPORT_EXPIRED"},
		{name: "secondary-auth", err: datarights.ErrInvalidCredentials, want: http.StatusForbidden, code: "REAUTHENTICATION_FAILED"},
		{name: "cancel-closed", err: datarights.ErrCancellationClosed, want: http.StatusConflict, code: "CANCELLATION_WINDOW_CLOSED"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			fake := &fakeDataRightsService{err: test.err}
			handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, DataRightsService: fake})
			request := httptest.NewRequest(http.MethodGet, "/api/v1/data-rights/exports/"+requestID.String(), nil)
			request.Header.Set("Authorization", "Bearer access")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != test.want || !strings.Contains(response.Body.String(), test.code) {
				t.Fatalf("status=%d want=%d body=%s", response.Code, test.want, response.Body.String())
			}
		})
	}
}

var _ DataRightsService = (*fakeDataRightsService)(nil)
var _ = errors.Is
