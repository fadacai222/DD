package push

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type UnifiedPushConfig struct {
	HTTPClient *http.Client
}

type UnifiedPushProvider struct {
	httpClient *http.Client
}

func NewUnifiedPushProvider(config UnifiedPushConfig) *UnifiedPushProvider {
	client := config.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	return &UnifiedPushProvider{httpClient: client}
}

func (provider *UnifiedPushProvider) Send(ctx context.Context, delivery Delivery) (ProviderResult, error) {
	body, err := json.Marshal(map[string]any{
		"title": delivery.Title,
		"body":  delivery.Body,
		"data":  delivery.Data,
	})
	if err != nil {
		return ProviderResult{}, fmt.Errorf("encode UnifiedPush payload: %w", err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, delivery.Endpoint, strings.NewReader(string(body)))
	if err != nil {
		return ProviderResult{}, fmt.Errorf("create UnifiedPush request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Urgency", func() string {
		if delivery.HighPriority {
			return "high"
		}
		return "normal"
	}())
	if delivery.CollapseKey != "" {
		request.Header.Set("Topic", truncateString(delivery.CollapseKey, 32))
	}
	response, err := provider.httpClient.Do(request)
	if err != nil {
		return ProviderResult{}, fmt.Errorf("%w: UnifiedPush request failed: %v", ErrRetryable, err)
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		return ProviderResult{MessageID: response.Header.Get("Location")}, nil
	}
	if response.StatusCode == http.StatusGone || response.StatusCode == http.StatusNotFound {
		return ProviderResult{InvalidToken: true}, fmt.Errorf("UnifiedPush endpoint is gone: HTTP %d", response.StatusCode)
	}
	if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
		return ProviderResult{}, fmt.Errorf("%w: UnifiedPush HTTP %d", ErrRetryable, response.StatusCode)
	}
	return ProviderResult{}, fmt.Errorf("UnifiedPush HTTP %d: %s", response.StatusCode, truncateProviderError(responseBody))
}
