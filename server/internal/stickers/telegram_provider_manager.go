package stickers

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"time"
)

type TelegramIntegrationSource string

const (
	TelegramIntegrationSourceNone        TelegramIntegrationSource = "NONE"
	TelegramIntegrationSourceEnvironment TelegramIntegrationSource = "ENVIRONMENT"
	TelegramIntegrationSourceAdmin       TelegramIntegrationSource = "ADMIN_OVERRIDE"
)

type TelegramBotInfo struct {
	ID       int64  `json:"id"`
	Username string `json:"username,omitempty"`
}

type TelegramRelayStatus struct {
	Configured bool                      `json:"configured"`
	Source     TelegramIntegrationSource `json:"source"`
	UpdatedAt  *time.Time                `json:"updatedAt,omitempty"`
}

type TelegramProviderManager struct {
	mu         sync.RWMutex
	provider   *TelegramBotProvider
	baseURL    string
	httpClient *http.Client
	source     TelegramIntegrationSource
	updatedAt  *time.Time
}

func NewTelegramProviderManager(config TelegramBotProviderConfig, source TelegramIntegrationSource, updatedAt *time.Time) (*TelegramProviderManager, error) {
	manager := &TelegramProviderManager{
		baseURL:    strings.TrimSpace(config.BaseURL),
		httpClient: config.HTTPClient,
		source:     TelegramIntegrationSourceNone,
	}
	if strings.TrimSpace(config.Token) == "" {
		return manager, nil
	}
	if err := manager.ActivateToken(config.Token, source, updatedAt); err != nil {
		return nil, err
	}
	return manager, nil
}

func (manager *TelegramProviderManager) GetStickerSet(ctx context.Context, setName string) (TelegramStickerSet, error) {
	provider := manager.currentProvider()
	if provider == nil {
		return TelegramStickerSet{}, ErrTelegramRelayNotConfigured
	}
	return provider.GetStickerSet(ctx, setName)
}

func (manager *TelegramProviderManager) DownloadSticker(ctx context.Context, fileID string, maxBytes int64) (TelegramFile, error) {
	provider := manager.currentProvider()
	if provider == nil {
		return TelegramFile{}, ErrTelegramRelayNotConfigured
	}
	return provider.DownloadSticker(ctx, fileID, maxBytes)
}

func (manager *TelegramProviderManager) ValidateToken(ctx context.Context, rawToken string) (TelegramBotInfo, error) {
	provider, err := NewTelegramBotProvider(TelegramBotProviderConfig{
		Token:      rawToken,
		BaseURL:    manager.baseURL,
		HTTPClient: manager.httpClient,
	})
	if err != nil {
		return TelegramBotInfo{}, err
	}
	return provider.GetMe(ctx)
}

func (manager *TelegramProviderManager) ActivateToken(rawToken string, source TelegramIntegrationSource, updatedAt *time.Time) error {
	provider, err := NewTelegramBotProvider(TelegramBotProviderConfig{
		Token:      rawToken,
		BaseURL:    manager.baseURL,
		HTTPClient: manager.httpClient,
	})
	if err != nil {
		return err
	}
	if source == "" || source == TelegramIntegrationSourceNone {
		source = TelegramIntegrationSourceAdmin
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	manager.provider = provider
	manager.source = source
	manager.updatedAt = copyTimePointer(updatedAt)
	return nil
}

func (manager *TelegramProviderManager) Test(ctx context.Context) (TelegramBotInfo, error) {
	provider := manager.currentProvider()
	if provider == nil {
		return TelegramBotInfo{}, ErrTelegramRelayNotConfigured
	}
	return provider.GetMe(ctx)
}

func (manager *TelegramProviderManager) Status() TelegramRelayStatus {
	manager.mu.RLock()
	defer manager.mu.RUnlock()
	return TelegramRelayStatus{
		Configured: manager.provider != nil,
		Source:     manager.source,
		UpdatedAt:  copyTimePointer(manager.updatedAt),
	}
}

func (manager *TelegramProviderManager) currentProvider() *TelegramBotProvider {
	manager.mu.RLock()
	defer manager.mu.RUnlock()
	return manager.provider
}

func copyTimePointer(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copied := value.UTC()
	return &copied
}
