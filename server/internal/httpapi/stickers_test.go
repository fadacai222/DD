package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/stickers"
	"github.com/google/uuid"
)

type fakeStickersService struct {
	listCustomPrincipal account.Principal
	createPrincipal     account.Principal
	createInput         stickers.CreateCustomStickerInput
	deleteInput         stickers.DeleteCustomStickersInput
	reorderInput        stickers.ReorderCustomStickersInput
	importSetName       string
	removePackID        uuid.UUID
	listCustomErr       error
	createErr           error
	importErr           error
}

func (fake *fakeStickersService) ListCustomStickers(_ context.Context, principal account.Principal) ([]stickers.CustomSticker, error) {
	fake.listCustomPrincipal = principal
	if fake.listCustomErr != nil {
		return nil, fake.listCustomErr
	}
	return []stickers.CustomSticker{{
		ID: uuid.NewString(), MediaID: uuid.NewString(), MIMEType: "image/webp",
		Width: 512, Height: 512, SizeBytes: 1024, SortOrder: 0,
		CreatedAt: time.Date(2026, 8, 10, 7, 30, 0, 0, time.UTC),
	}}, nil
}

func (fake *fakeStickersService) CreateCustomSticker(_ context.Context, principal account.Principal, input stickers.CreateCustomStickerInput) (stickers.CustomSticker, error) {
	fake.createPrincipal = principal
	fake.createInput = input
	if fake.createErr != nil {
		return stickers.CustomSticker{}, fake.createErr
	}
	return stickers.CustomSticker{ID: uuid.NewString(), MediaID: input.MediaID, MIMEType: "image/webp", Width: input.Width, Height: input.Height, SizeBytes: 1024}, nil
}

func (fake *fakeStickersService) DeleteCustomStickers(_ context.Context, _ account.Principal, input stickers.DeleteCustomStickersInput) (int, error) {
	fake.deleteInput = input
	return len(input.StickerIDs), nil
}

func (fake *fakeStickersService) ReorderCustomStickers(_ context.Context, _ account.Principal, input stickers.ReorderCustomStickersInput) error {
	fake.reorderInput = input
	return nil
}

func (fake *fakeStickersService) ListStickerPacks(_ context.Context, _ account.Principal) ([]stickers.StickerPack, error) {
	return []stickers.StickerPack{{ID: uuid.NewString(), SetName: "Animals_by_TestBot", Title: "Animals", Items: []stickers.StickerItem{}}}, nil
}

func (fake *fakeStickersService) ImportTelegramPack(_ context.Context, _ account.Principal, setName string) (stickers.StickerPack, error) {
	fake.importSetName = setName
	if fake.importErr != nil {
		return stickers.StickerPack{}, fake.importErr
	}
	return stickers.StickerPack{ID: uuid.NewString(), SetName: setName, Title: "Animals", Items: []stickers.StickerItem{}}, nil
}

func (fake *fakeStickersService) RemoveStickerPack(_ context.Context, _ account.Principal, packID uuid.UUID) error {
	fake.removePackID = packID
	return nil
}

func TestCustomStickersEndpointsAuthenticateAndForwardOwnerOperations(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &fakeStickersService{}
	handler := NewHandler(Config{
		AuthService:     &stablePrincipalAuthService{principal: principal},
		StickersService: service,
	})

	mediaID := uuid.NewString()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/stickers/custom", strings.NewReader(`{"mediaId":"`+mediaID+`","width":512,"height":512}`))
	request.Header.Set("Authorization", "Bearer token")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", response.Code, response.Body.String())
	}
	if service.createPrincipal != principal || service.createInput.MediaID != mediaID || service.createInput.Width != 512 {
		t.Fatalf("create forwarding mismatch principal=%#v input=%#v", service.createPrincipal, service.createInput)
	}

	request = httptest.NewRequest(http.MethodGet, "/api/v1/stickers/custom", nil)
	request.Header.Set("Authorization", "Bearer token")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || service.listCustomPrincipal != principal {
		t.Fatalf("list status=%d principal=%#v body=%s", response.Code, service.listCustomPrincipal, response.Body.String())
	}
	var listEnvelope struct {
		Data struct {
			Items []stickers.CustomSticker `json:"items"`
		} `json:"data"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &listEnvelope); err != nil || len(listEnvelope.Data.Items) != 1 {
		t.Fatalf("decode custom list err=%v data=%#v", err, listEnvelope.Data)
	}
}

func TestTelegramStickerImportMapsRelayConfigurationAndUsesSetNameOnly(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &fakeStickersService{importErr: stickers.ErrTelegramRelayNotConfigured}
	handler := NewHandler(Config{
		AuthService:     &stablePrincipalAuthService{principal: principal},
		StickersService: service,
	})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/stickers/packs/telegram", strings.NewReader(`{"setName":"Animals_by_TestBot"}`))
	request.Header.Set("Authorization", "Bearer token")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if service.importSetName != "Animals_by_TestBot" {
		t.Fatalf("setName=%q", service.importSetName)
	}
	if !strings.Contains(response.Body.String(), "TELEGRAM_STICKER_RELAY_NOT_CONFIGURED") {
		t.Fatalf("missing stable relay error code: %s", response.Body.String())
	}
}

func TestStickerPackDeleteForwardsStablePackID(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &fakeStickersService{}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, StickersService: service})
	packID := uuid.New()
	request := httptest.NewRequest(http.MethodDelete, "/api/v1/stickers/packs/"+packID.String(), nil)
	request.Header.Set("Authorization", "Bearer token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK || service.removePackID != packID {
		t.Fatalf("status=%d removePackID=%s body=%s", response.Code, service.removePackID, response.Body.String())
	}
}

func TestStickerErrorMappingDoesNotExposeProviderDetails(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	service := &fakeStickersService{importErr: errors.Join(stickers.ErrTelegramProviderUnavailable, errors.New("upstream token=secret"))}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, StickersService: service})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/stickers/packs/telegram", strings.NewReader(`{"setName":"Animals_by_TestBot"}`))
	request.Header.Set("Authorization", "Bearer token")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "secret") || strings.Contains(response.Body.String(), "token=") {
		t.Fatalf("provider details leaked: %s", response.Body.String())
	}
}
