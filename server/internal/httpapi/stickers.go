package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/stickers"
	"github.com/google/uuid"
)

type StickersService interface {
	ListCustomStickers(ctx context.Context, principal account.Principal) ([]stickers.CustomSticker, error)
	CreateCustomSticker(ctx context.Context, principal account.Principal, input stickers.CreateCustomStickerInput) (stickers.CustomSticker, error)
	DeleteCustomStickers(ctx context.Context, principal account.Principal, input stickers.DeleteCustomStickersInput) (int, error)
	ReorderCustomStickers(ctx context.Context, principal account.Principal, input stickers.ReorderCustomStickersInput) error
	ListStickerPacks(ctx context.Context, principal account.Principal) ([]stickers.StickerPack, error)
	ImportTelegramPack(ctx context.Context, principal account.Principal, setName string) (stickers.StickerPack, error)
	RemoveStickerPack(ctx context.Context, principal account.Principal, packID uuid.UUID) error
}

type importTelegramPackRequest struct {
	SetName string `json:"setName"`
}

func (s *server) handleCustomStickers(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireStickersPrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodGet:
		items, err := s.stickers.ListCustomStickers(request.Context(), principal)
		if err != nil {
			s.writeStickersError(response, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"items": items})
	case http.MethodPost:
		var input stickers.CreateCustomStickerInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		item, err := s.stickers.CreateCustomSticker(request.Context(), principal, input)
		if err != nil {
			s.writeStickersError(response, err)
			return
		}
		writeSuccess(response, http.StatusCreated, item)
	case http.MethodDelete:
		var input stickers.DeleteCustomStickersInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		deleted, err := s.stickers.DeleteCustomStickers(request.Context(), principal, input)
		if err != nil {
			s.writeStickersError(response, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"deleted": deleted})
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPost, http.MethodDelete)
	}
}

func (s *server) handleCustomStickerOrder(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPut {
		methodNotAllowed(response, http.MethodPut)
		return
	}
	principal, ok := s.requireStickersPrincipal(response, request)
	if !ok {
		return
	}
	var input stickers.ReorderCustomStickersInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	if err := s.stickers.ReorderCustomStickers(request.Context(), principal, input); err != nil {
		s.writeStickersError(response, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"updated": true})
}

func (s *server) handleStickerPacks(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, ok := s.requireStickersPrincipal(response, request)
	if !ok {
		return
	}
	items, err := s.stickers.ListStickerPacks(request.Context(), principal)
	if err != nil {
		s.writeStickersError(response, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleTelegramStickerPackImport(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requireStickersPrincipal(response, request)
	if !ok {
		return
	}
	var input importTelegramPackRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	pack, err := s.stickers.ImportTelegramPack(request.Context(), principal, input.SetName)
	if err != nil {
		s.writeStickersError(response, err)
		return
	}
	writeSuccess(response, http.StatusOK, pack)
}

func (s *server) handleStickerPackByID(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodDelete {
		methodNotAllowed(response, http.MethodDelete)
		return
	}
	principal, ok := s.requireStickersPrincipal(response, request)
	if !ok {
		return
	}
	rawID := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/stickers/packs/"), "/")
	packID, err := uuid.Parse(rawID)
	if err != nil || packID == uuid.Nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_STICKER_PACK", "A valid sticker pack id is required")
		return
	}
	if err := s.stickers.RemoveStickerPack(request.Context(), principal, packID); err != nil {
		s.writeStickersError(response, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"removed": true})
}

func (s *server) requireStickersPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.stickers == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "STICKERS_UNAVAILABLE", "Sticker service is unavailable")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) writeStickersError(response http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, stickers.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_STICKER_INPUT", "Sticker input is invalid")
	case errors.Is(err, stickers.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "STICKER_FORBIDDEN", "Sticker operation is not allowed")
	case errors.Is(err, stickers.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "STICKER_NOT_FOUND", "Sticker resource was not found")
	case errors.Is(err, stickers.ErrConflict):
		writeAPIError(response, http.StatusConflict, "STICKER_CONFLICT", "Sticker library state conflicts with this operation")
	case errors.Is(err, stickers.ErrRateLimited):
		writeAPIError(response, http.StatusTooManyRequests, "STICKER_RATE_LIMITED", "Sticker import rate limit exceeded")
	case errors.Is(err, stickers.ErrTelegramRelayNotConfigured):
		writeAPIError(response, http.StatusServiceUnavailable, "TELEGRAM_STICKER_RELAY_NOT_CONFIGURED", "Telegram sticker relay is not configured on this DD instance")
	case errors.Is(err, stickers.ErrTelegramStickerSetNotFound):
		writeAPIError(response, http.StatusNotFound, "TELEGRAM_STICKER_PACK_NOT_FOUND", "Telegram sticker pack was not found")
	case errors.Is(err, stickers.ErrTelegramProviderUnauthorized):
		writeAPIError(response, http.StatusServiceUnavailable, "TELEGRAM_STICKER_RELAY_AUTH_FAILED", "Telegram sticker relay authentication failed")
	case errors.Is(err, stickers.ErrTelegramProviderRateLimited):
		writeAPIError(response, http.StatusTooManyRequests, "TELEGRAM_STICKER_RELAY_RATE_LIMITED", "Telegram sticker relay is rate limited; try again later")
	case errors.Is(err, stickers.ErrTelegramProviderTimeout):
		writeAPIError(response, http.StatusGatewayTimeout, "TELEGRAM_STICKER_RELAY_TIMEOUT", "Telegram sticker relay request timed out")
	case errors.Is(err, stickers.ErrTelegramStickerFormatUnsupported):
		writeAPIError(response, http.StatusUnprocessableEntity, "TELEGRAM_STICKER_FORMAT_UNSUPPORTED", "This sticker pack does not contain a supported Telegram sticker format")
	case errors.Is(err, stickers.ErrTelegramStickerDownloadTooLarge):
		writeAPIError(response, http.StatusUnprocessableEntity, "TELEGRAM_STICKER_TOO_LARGE", "A Telegram sticker exceeds the configured size limit")
	case errors.Is(err, stickers.ErrTelegramStickerDownloadInvalid):
		writeAPIError(response, http.StatusBadGateway, "TELEGRAM_STICKER_INVALID", "Telegram returned an invalid sticker file")
	case errors.Is(err, stickers.ErrTelegramProviderUnavailable):
		writeAPIError(response, http.StatusBadGateway, "TELEGRAM_STICKER_RELAY_UNAVAILABLE", "Telegram sticker relay is temporarily unavailable")
	default:
		writeAPIError(response, http.StatusInternalServerError, "STICKER_INTERNAL_ERROR", "Sticker operation failed")
	}
}
