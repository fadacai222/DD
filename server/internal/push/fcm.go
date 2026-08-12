package push

import (
	"context"
	"crypto/rsa"
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

const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

type FCMConfig struct {
	ServiceAccountJSON string
	HTTPClient         *http.Client
	Now                func() time.Time
}

type FCMProvider struct {
	projectID   string
	clientEmail string
	tokenURI    string
	privateKey  *rsa.PrivateKey
	httpClient  *http.Client
	now         func() time.Time
	mu          sync.Mutex
	accessToken string
	tokenExpiry time.Time
}

type fcmServiceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

func NewFCMProvider(config FCMConfig) (*FCMProvider, error) {
	raw := strings.TrimSpace(config.ServiceAccountJSON)
	if raw == "" {
		return nil, ErrProviderUnavailable
	}
	var credential fcmServiceAccount
	if err := json.Unmarshal([]byte(raw), &credential); err != nil {
		return nil, fmt.Errorf("decode FCM service account: %w", err)
	}
	credential.ProjectID = strings.TrimSpace(credential.ProjectID)
	credential.ClientEmail = strings.TrimSpace(credential.ClientEmail)
	credential.TokenURI = strings.TrimSpace(credential.TokenURI)
	if credential.TokenURI == "" {
		credential.TokenURI = "https://oauth2.googleapis.com/token"
	}
	if credential.ProjectID == "" || credential.ClientEmail == "" || strings.TrimSpace(credential.PrivateKey) == "" {
		return nil, errors.New("FCM service account requires project_id, client_email and private_key")
	}
	block, _ := pem.Decode([]byte(credential.PrivateKey))
	if block == nil {
		return nil, errors.New("FCM private key is not PEM")
	}
	keyValue, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse FCM private key: %w", err)
	}
	privateKey, ok := keyValue.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("FCM private key must be RSA")
	}
	client := config.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &FCMProvider{
		projectID: credential.ProjectID, clientEmail: credential.ClientEmail,
		tokenURI: credential.TokenURI, privateKey: privateKey, httpClient: client, now: now,
	}, nil
}

func (provider *FCMProvider) Send(ctx context.Context, delivery Delivery) (ProviderResult, error) {
	accessToken, err := provider.getAccessToken(ctx)
	if err != nil {
		return ProviderResult{}, err
	}
	data := make(map[string]string, len(delivery.Data)+2)
	for key, value := range delivery.Data {
		data[key] = value
	}
	if delivery.Title != "" {
		data["title"] = delivery.Title
	}
	if delivery.Body != "" {
		data["body"] = delivery.Body
	}
	visible := delivery.Title != "" || delivery.Body != ""
	message := map[string]any{
		"token": delivery.Endpoint,
		"data":  data,
		"android": map[string]any{
			"priority": func() string {
				if delivery.HighPriority || visible {
					return "HIGH"
				}
				return "NORMAL"
			}(),
			"collapse_key": delivery.CollapseKey,
		},
	}
	// Android must stay data-only so DD can render MessagingStyle, the sender
	// avatar and its own notification icon. Apple still receives an alert when
	// FCM is used as the iOS transport via the APNS-specific payload.
	if visible || delivery.BadgeOnly {
		aps := map[string]any{"badge": delivery.Badge}
		priority := "5"
		if visible {
			aps["alert"] = map[string]string{"title": delivery.Title, "body": delivery.Body}
			aps["sound"] = "default"
			priority = "10"
		}
		if delivery.ConversationID != "" {
			aps["thread-id"] = delivery.ConversationID
		}
		message["apns"] = map[string]any{
			"headers": map[string]string{"apns-priority": priority},
			"payload": map[string]any{"aps": aps},
		}
	}
	body, err := json.Marshal(map[string]any{"message": message})
	if err != nil {
		return ProviderResult{}, fmt.Errorf("encode FCM request: %w", err)
	}
	endpoint := "https://fcm.googleapis.com/v1/projects/" + url.PathEscape(provider.projectID) + "/messages:send"
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(body)))
	if err != nil {
		return ProviderResult{}, fmt.Errorf("create FCM request: %w", err)
	}
	request.Header.Set("Authorization", "Bearer "+accessToken)
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	response, err := provider.httpClient.Do(request)
	if err != nil {
		return ProviderResult{}, fmt.Errorf("%w: FCM request failed: %v", ErrRetryable, err)
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 128*1024))
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		var decoded struct {
			Name string `json:"name"`
		}
		_ = json.Unmarshal(responseBody, &decoded)
		return ProviderResult{MessageID: decoded.Name}, nil
	}
	invalid := fcmInvalidToken(response.StatusCode, responseBody)
	if invalid {
		return ProviderResult{InvalidToken: true}, fmt.Errorf("FCM rejected registration token: HTTP %d", response.StatusCode)
	}
	if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
		return ProviderResult{}, fmt.Errorf("%w: FCM HTTP %d", ErrRetryable, response.StatusCode)
	}
	return ProviderResult{}, fmt.Errorf("FCM HTTP %d: %s", response.StatusCode, truncateProviderError(responseBody))
}

func (provider *FCMProvider) getAccessToken(ctx context.Context) (string, error) {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	now := provider.now().UTC()
	if provider.accessToken != "" && provider.tokenExpiry.After(now.Add(2*time.Minute)) {
		return provider.accessToken, nil
	}
	claims := jwt.MapClaims{
		"iss":   provider.clientEmail,
		"scope": fcmScope,
		"aud":   provider.tokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
	assertion, err := jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(provider.privateKey)
	if err != nil {
		return "", fmt.Errorf("sign FCM OAuth assertion: %w", err)
	}
	form := url.Values{}
	form.Set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer")
	form.Set("assertion", assertion)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, provider.tokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("create FCM OAuth request: %w", err)
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := provider.httpClient.Do(request)
	if err != nil {
		return "", fmt.Errorf("%w: FCM OAuth request failed: %v", ErrRetryable, err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 128*1024))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
			return "", fmt.Errorf("%w: FCM OAuth HTTP %d", ErrRetryable, response.StatusCode)
		}
		return "", fmt.Errorf("FCM OAuth HTTP %d: %s", response.StatusCode, truncateProviderError(body))
	}
	var tokenResponse struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tokenResponse); err != nil || strings.TrimSpace(tokenResponse.AccessToken) == "" {
		return "", errors.New("FCM OAuth response missing access_token")
	}
	if tokenResponse.ExpiresIn <= 0 {
		tokenResponse.ExpiresIn = 3600
	}
	provider.accessToken = tokenResponse.AccessToken
	provider.tokenExpiry = now.Add(time.Duration(tokenResponse.ExpiresIn) * time.Second)
	return provider.accessToken, nil
}

func fcmInvalidToken(status int, body []byte) bool {
	if status != http.StatusBadRequest && status != http.StatusNotFound {
		return false
	}
	text := strings.ToUpper(string(body))
	return strings.Contains(text, "UNREGISTERED") || strings.Contains(text, "INVALID_ARGUMENT") && strings.Contains(text, "TOKEN")
}

func truncateProviderError(body []byte) string {
	text := strings.TrimSpace(string(body))
	if len(text) > 500 {
		text = text[:500]
	}
	return text
}
