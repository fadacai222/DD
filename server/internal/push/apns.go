package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type APNSConfig struct {
	KeyID         string
	TeamID        string
	BundleID      string
	PrivateKeyPEM string
	HTTPClient    *http.Client
	Now           func() time.Time
}

type APNSProvider struct {
	keyID      string
	teamID     string
	bundleID   string
	privateKey *ecdsa.PrivateKey
	httpClient *http.Client
	now        func() time.Time
	mu         sync.Mutex
	token      string
	tokenAt    time.Time
}

func NewAPNSProvider(config APNSConfig) (*APNSProvider, error) {
	keyID := strings.TrimSpace(config.KeyID)
	teamID := strings.TrimSpace(config.TeamID)
	bundleID := strings.TrimSpace(config.BundleID)
	keyPEM := strings.TrimSpace(config.PrivateKeyPEM)
	if keyID == "" || teamID == "" || bundleID == "" || keyPEM == "" {
		return nil, ErrProviderUnavailable
	}
	block, _ := pem.Decode([]byte(keyPEM))
	if block == nil {
		return nil, errors.New("APNs private key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}
	privateKey, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNs private key must be ECDSA")
	}
	client := config.HTTPClient
	if client == nil {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.ForceAttemptHTTP2 = true
		client = &http.Client{Transport: transport, Timeout: 15 * time.Second}
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &APNSProvider{keyID: keyID, teamID: teamID, bundleID: bundleID, privateKey: privateKey, httpClient: client, now: now}, nil
}

func (provider *APNSProvider) Send(ctx context.Context, delivery Delivery) (ProviderResult, error) {
	token, err := provider.providerToken()
	if err != nil {
		return ProviderResult{}, err
	}
	host := "https://api.push.apple.com"
	if strings.EqualFold(delivery.Environment, "SANDBOX") {
		host = "https://api.sandbox.push.apple.com"
	}
	aps := map[string]any{"badge": delivery.Badge}
	if !delivery.BadgeOnly {
		aps["alert"] = map[string]string{"title": delivery.Title, "body": delivery.Body}
		aps["sound"] = "default"
	}
	if delivery.ConversationID != "" {
		aps["thread-id"] = delivery.ConversationID
	}
	payload := map[string]any{
		"aps": aps,
		"dd":  delivery.Data,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return ProviderResult{}, fmt.Errorf("encode APNs payload: %w", err)
	}
	requestURL := host + "/3/device/" + url.PathEscape(delivery.Endpoint)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, requestURL, strings.NewReader(string(body)))
	if err != nil {
		return ProviderResult{}, fmt.Errorf("create APNs request: %w", err)
	}
	request.Header.Set("authorization", "bearer "+token)
	request.Header.Set("apns-topic", provider.bundleID)
	request.Header.Set("apns-push-type", "alert")
	if delivery.HighPriority && !delivery.BadgeOnly {
		request.Header.Set("apns-priority", "10")
	} else {
		request.Header.Set("apns-priority", "5")
	}
	if delivery.CollapseKey != "" {
		request.Header.Set("apns-collapse-id", truncateString(delivery.CollapseKey, 64))
	}
	request.Header.Set("content-type", "application/json")
	response, err := provider.httpClient.Do(request)
	if err != nil {
		return ProviderResult{}, fmt.Errorf("%w: APNs request failed: %v", ErrRetryable, err)
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if response.StatusCode == http.StatusOK {
		return ProviderResult{MessageID: response.Header.Get("apns-id")}, nil
	}
	var failure struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(responseBody, &failure)
	invalid := response.StatusCode == http.StatusGone || failure.Reason == "BadDeviceToken" || failure.Reason == "Unregistered" || failure.Reason == "DeviceTokenNotForTopic"
	if invalid {
		return ProviderResult{InvalidToken: true}, fmt.Errorf("APNs rejected device token: %s", failure.Reason)
	}
	if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
		return ProviderResult{}, fmt.Errorf("%w: APNs HTTP %d: %s", ErrRetryable, response.StatusCode, failure.Reason)
	}
	return ProviderResult{}, fmt.Errorf("APNs HTTP %d: %s", response.StatusCode, strings.TrimSpace(failure.Reason))
}

func (provider *APNSProvider) providerToken() (string, error) {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	now := provider.now().UTC()
	if provider.token != "" && now.Sub(provider.tokenAt) < 50*time.Minute {
		return provider.token, nil
	}
	claims := jwt.MapClaims{"iss": provider.teamID, "iat": now.Unix()}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = provider.keyID
	signed, err := token.SignedString(provider.privateKey)
	if err != nil {
		return "", fmt.Errorf("sign APNs provider token: %w", err)
	}
	provider.token = signed
	provider.tokenAt = now
	return signed, nil
}

func truncateString(value string, max int) string {
	if len(value) <= max {
		return value
	}
	return value[:max]
}
