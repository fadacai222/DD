package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/media"
	"github.com/google/uuid"
)

type fakeMediaService struct {
	createPrincipal account.Principal
	createInput     media.CreateUploadInput
	completeID      uuid.UUID
	downloadID      uuid.UUID
	createErr       error
	completeErr     error
}

func (fake *fakeMediaService) CreateUpload(_ context.Context, principal account.Principal, input media.CreateUploadInput) (media.UploadGrant, error) {
	fake.createPrincipal = principal
	fake.createInput = input
	if fake.createErr != nil {
		return media.UploadGrant{}, fake.createErr
	}
	return media.UploadGrant{
		UploadID:        "00000000-0000-0000-0000-000000000111",
		MediaID:         "00000000-0000-0000-0000-000000000222",
		UploadURL:       "http://storage.example/upload",
		ExpiresAt:       time.Date(2026, 8, 8, 6, 10, 0, 0, time.UTC),
		RequiredHeaders: map[string]string{"Content-Type": "image/jpeg"},
	}, nil
}

func (fake *fakeMediaService) CompleteUpload(_ context.Context, _ account.Principal, uploadID uuid.UUID) (media.CompleteUploadResult, error) {
	fake.completeID = uploadID
	if fake.completeErr != nil {
		return media.CompleteUploadResult{}, fake.completeErr
	}
	return media.CompleteUploadResult{Media: media.MediaObject{ID: "00000000-0000-0000-0000-000000000222", Status: media.StatusReady}}, nil
}

func (fake *fakeMediaService) GetMedia(_ context.Context, _ account.Principal, mediaID uuid.UUID) (media.MediaObject, error) {
	return media.MediaObject{ID: mediaID.String(), Status: media.StatusReady}, nil
}

func (fake *fakeMediaService) CreateDownloadURL(_ context.Context, _ account.Principal, mediaID uuid.UUID) (string, time.Time, error) {
	fake.downloadID = mediaID
	return "http://storage.example/download", time.Date(2026, 8, 8, 6, 5, 0, 0, time.UTC), nil
}

func TestMediaUploadEndpointAuthenticatesAndForwardsReservation(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &fakeMediaService{}
	handler := NewHandler(Config{
		AuthService:  &stablePrincipalAuthService{principal: principal},
		MediaService: service,
	})
	body := `{"fileName":"photo.jpg","size":1234,"mimeType":"image/jpeg","sha256":"` + strings.Repeat("a", 64) + `","purpose":"CHAT_IMAGE"}`
	request := httptest.NewRequest(http.MethodPost, "/api/v1/media/uploads", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer token")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusCreated {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if service.createPrincipal != principal || service.createInput.Purpose != media.PurposeChatImage || service.createInput.Size != 1234 {
		t.Fatalf("forwarded media request mismatch: principal=%#v input=%#v", service.createPrincipal, service.createInput)
	}
	var envelope struct {
		Data media.UploadGrant `json:"data"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil || envelope.Data.UploadID == "" {
		t.Fatalf("decode media grant: err=%v data=%#v", err, envelope.Data)
	}
}

func TestMediaCompleteMapsObjectMismatchToConflict(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &fakeMediaService{completeErr: media.ErrObjectMismatch}
	handler := NewHandler(Config{
		AuthService:  &stablePrincipalAuthService{principal: principal},
		MediaService: service,
	})
	uploadID := uuid.New()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/media/uploads/"+uploadID.String()+"/complete", nil)
	request.Header.Set("Authorization", "Bearer token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusConflict {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if service.completeID != uploadID {
		t.Fatalf("completed upload = %s want %s", service.completeID, uploadID)
	}
}

func TestMediaDownloadURLRequiresAuthenticatedService(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &fakeMediaService{}
	handler := NewHandler(Config{
		AuthService:  &stablePrincipalAuthService{principal: principal},
		MediaService: service,
	})
	mediaID := uuid.New()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/media/"+mediaID.String()+"/download-url", nil)
	request.Header.Set("Authorization", "Bearer token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if service.downloadID != mediaID {
		t.Fatalf("download media = %s want %s", service.downloadID, mediaID)
	}
}
