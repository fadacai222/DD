package transcription

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const maxProviderResponseBytes = 1024 * 1024

type WhisperHTTPConfig struct {
	Endpoint   string
	Model      string
	Credential string
	HTTPClient *http.Client
}

type WhisperHTTPProvider struct {
	endpoint   string
	model      string
	credential string
	client     *http.Client
}

func NewWhisperHTTPProvider(config WhisperHTTPConfig) (*WhisperHTTPProvider, error) {
	endpoint := strings.TrimSpace(config.Endpoint)
	model := strings.TrimSpace(config.Model)
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.User != nil || parsed.Fragment != "" {
		return nil, ErrInvalidInput
	}
	if model == "" {
		return nil, ErrInvalidInput
	}
	client := config.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 2 * time.Minute}
	}
	return &WhisperHTTPProvider{
		endpoint: endpoint,
		model: model,
		credential: strings.TrimSpace(config.Credential),
		client: client,
	}, nil
}

func (provider *WhisperHTTPProvider) Transcribe(ctx context.Context, input ProviderInput) (ProviderResult, error) {
	if len(input.Audio) == 0 {
		return ProviderResult{}, ErrProviderPerm
	}
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	fileName := strings.TrimSpace(input.FileName)
	if fileName == "" {
		fileName = "voice.bin"
	}
	part, err := writer.CreateFormFile("file", fileName)
	if err != nil {
		return ProviderResult{}, fmt.Errorf("create transcription multipart: %w", err)
	}
	if _, err := part.Write(input.Audio); err != nil {
		return ProviderResult{}, fmt.Errorf("write transcription multipart: %w", err)
	}
	if err := writer.WriteField("model", provider.model); err != nil {
		return ProviderResult{}, fmt.Errorf("write transcription model: %w", err)
	}
	if err := writer.Close(); err != nil {
		return ProviderResult{}, fmt.Errorf("finalize transcription multipart: %w", err)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, provider.endpoint, &body)
	if err != nil {
		return ProviderResult{}, fmt.Errorf("create transcription request: %w", err)
	}
	request.Header.Set("Content-Type", writer.FormDataContentType())
	if provider.credential != "" {
		request.Header.Set("Authorization", "Bearer "+provider.credential)
	}
	response, err := provider.client.Do(request)
	if err != nil {
		return ProviderResult{}, fmt.Errorf("%w: provider request failed", ErrProviderTemp)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		if response.StatusCode == http.StatusRequestTimeout || response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
			return ProviderResult{}, fmt.Errorf("%w: provider http %d", ErrProviderTemp, response.StatusCode)
		}
		return ProviderResult{}, fmt.Errorf("%w: provider http %d", ErrProviderPerm, response.StatusCode)
	}
	limited := io.LimitReader(response.Body, maxProviderResponseBytes+1)
	payload, err := io.ReadAll(limited)
	if err != nil || len(payload) > maxProviderResponseBytes {
		return ProviderResult{}, fmt.Errorf("%w: provider response invalid", ErrProviderTemp)
	}
	var decoded struct {
		Text     string `json:"text"`
		Language string `json:"language"`
	}
	if err := json.Unmarshal(payload, &decoded); err != nil || strings.TrimSpace(decoded.Text) == "" {
		return ProviderResult{}, fmt.Errorf("%w: provider response invalid", ErrProviderPerm)
	}
	return ProviderResult{
		Transcript: strings.TrimSpace(decoded.Text),
		Language: strings.TrimSpace(decoded.Language),
		Model: provider.model,
	}, nil
}
