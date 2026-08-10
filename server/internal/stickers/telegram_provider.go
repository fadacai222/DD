package stickers

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

type TelegramProvider interface {
	GetStickerSet(ctx context.Context, setName string) (TelegramStickerSet, error)
	DownloadSticker(ctx context.Context, fileID string, maxBytes int64) (TelegramFile, error)
}

type TelegramBotProvider struct {
	token      string
	baseURL    string
	httpClient *http.Client
}

type TelegramBotProviderConfig struct {
	Token      string
	BaseURL    string
	HTTPClient *http.Client
}

func NewTelegramBotProvider(config TelegramBotProviderConfig) (*TelegramBotProvider, error) {
	token := strings.TrimSpace(config.Token)
	if token == "" {
		return nil, ErrTelegramRelayNotConfigured
	}
	baseURL := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if baseURL == "" {
		baseURL = "https://api.telegram.org"
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, ErrInvalidInput
	}
	client := config.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	return &TelegramBotProvider{token: token, baseURL: baseURL, httpClient: client}, nil
}

type telegramAPIEnvelope[T any] struct {
	OK          bool   `json:"ok"`
	Result      T      `json:"result"`
	ErrorCode   int    `json:"error_code"`
	Description string `json:"description"`
}

type telegramStickerSetJSON struct {
	Name     string                `json:"name"`
	Title    string                `json:"title"`
	Stickers []telegramStickerJSON `json:"stickers"`
}

type telegramStickerJSON struct {
	FileID       string `json:"file_id"`
	FileUniqueID string `json:"file_unique_id"`
	Emoji        string `json:"emoji"`
	Width        int    `json:"width"`
	Height       int    `json:"height"`
	FileSize     int64  `json:"file_size"`
	IsAnimated   bool   `json:"is_animated"`
	IsVideo      bool   `json:"is_video"`
}

type telegramFileJSON struct {
	FilePath string `json:"file_path"`
	FileSize int64  `json:"file_size"`
}

func (provider *TelegramBotProvider) GetStickerSet(ctx context.Context, setName string) (TelegramStickerSet, error) {
	setName, err := normalizeSetName(setName)
	if err != nil {
		return TelegramStickerSet{}, err
	}
	var result telegramStickerSetJSON
	if err := provider.call(ctx, "getStickerSet", url.Values{"name": {setName}}, &result); err != nil {
		return TelegramStickerSet{}, err
	}
	if len(result.Stickers) > MaximumTelegramPackItems {
		return TelegramStickerSet{}, ErrInvalidInput
	}
	items := make([]TelegramSticker, 0, len(result.Stickers))
	for _, sticker := range result.Stickers {
		if strings.TrimSpace(sticker.FileID) == "" || strings.TrimSpace(sticker.FileUniqueID) == "" || sticker.Width <= 0 || sticker.Height <= 0 {
			return TelegramStickerSet{}, ErrTelegramProviderUnavailable
		}
		items = append(items, TelegramSticker{
			FileID:       sticker.FileID,
			FileUniqueID: sticker.FileUniqueID,
			Emoji:        sticker.Emoji,
			Width:        sticker.Width,
			Height:       sticker.Height,
			FileSize:     sticker.FileSize,
			IsAnimated:   sticker.IsAnimated,
			IsVideo:      sticker.IsVideo,
		})
	}
	name, err := normalizeSetName(result.Name)
	if err != nil || !strings.EqualFold(name, setName) {
		return TelegramStickerSet{}, ErrTelegramProviderUnavailable
	}
	title := strings.TrimSpace(result.Title)
	if title == "" || len([]rune(title)) > 128 {
		return TelegramStickerSet{}, ErrTelegramProviderUnavailable
	}
	return TelegramStickerSet{Name: name, Title: title, Stickers: items}, nil
}

func (provider *TelegramBotProvider) DownloadSticker(ctx context.Context, fileID string, maxBytes int64) (TelegramFile, error) {
	fileID = strings.TrimSpace(fileID)
	if fileID == "" || maxBytes <= 0 || maxBytes > MaximumTelegramStickerSize {
		return TelegramFile{}, ErrInvalidInput
	}
	var file telegramFileJSON
	if err := provider.call(ctx, "getFile", url.Values{"file_id": {fileID}}, &file); err != nil {
		return TelegramFile{}, err
	}
	if file.FileSize > maxBytes {
		return TelegramFile{}, ErrTelegramStickerDownloadTooLarge
	}
	cleaned := path.Clean("/" + strings.TrimSpace(file.FilePath))
	if cleaned == "/" || strings.Contains(cleaned, "..") {
		return TelegramFile{}, ErrTelegramProviderUnavailable
	}
	requestURL := provider.baseURL + "/file/bot" + provider.token + cleaned
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
	if err != nil {
		return TelegramFile{}, ErrTelegramProviderUnavailable
	}
	response, err := provider.httpClient.Do(request)
	if err != nil {
		return TelegramFile{}, ErrTelegramProviderUnavailable
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return TelegramFile{}, ErrTelegramProviderUnavailable
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBytes+1))
	if err != nil {
		return TelegramFile{}, ErrTelegramProviderUnavailable
	}
	if int64(len(body)) > maxBytes {
		return TelegramFile{}, ErrTelegramStickerDownloadTooLarge
	}
	if len(body) == 0 {
		return TelegramFile{}, ErrTelegramStickerDownloadInvalid
	}
	mimeType := strings.ToLower(strings.TrimSpace(strings.Split(response.Header.Get("Content-Type"), ";")[0]))
	if parsed, _, parseErr := mime.ParseMediaType(response.Header.Get("Content-Type")); parseErr == nil {
		mimeType = strings.ToLower(parsed)
	}
	if mimeType == "" || mimeType == "application/octet-stream" {
		mimeType = sniffTelegramStickerMIME(body)
	}
	return TelegramFile{
		Bytes:    body,
		MIMEType: mimeType,
		FileName: path.Base(cleaned),
	}, nil
}

func (provider *TelegramBotProvider) call(ctx context.Context, method string, values url.Values, result any) error {
	requestURL := provider.baseURL + "/bot" + provider.token + "/" + method + "?" + values.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
	if err != nil {
		return ErrTelegramProviderUnavailable
	}
	response, err := provider.httpClient.Do(request)
	if err != nil {
		return ErrTelegramProviderUnavailable
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024))
	if err != nil {
		return ErrTelegramProviderUnavailable
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return ErrTelegramProviderUnavailable
	}
	var envelope json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil {
		return ErrTelegramProviderUnavailable
	}
	var base struct {
		OK          bool            `json:"ok"`
		Result      json.RawMessage `json:"result"`
		ErrorCode   int             `json:"error_code"`
		Description string          `json:"description"`
	}
	if err := json.Unmarshal(envelope, &base); err != nil || !base.OK {
		return ErrTelegramProviderUnavailable
	}
	if err := json.Unmarshal(base.Result, result); err != nil {
		return ErrTelegramProviderUnavailable
	}
	return nil
}

func sniffTelegramStickerMIME(data []byte) string {
	if len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		return "image/webp"
	}
	return "application/octet-stream"
}

func validateStaticTelegramSticker(file TelegramFile) error {
	if file.MIMEType != "image/webp" || sniffTelegramStickerMIME(file.Bytes) != "image/webp" {
		return fmt.Errorf("%w: only static WebP stickers are currently supported", ErrTelegramStickerFormatUnsupported)
	}
	if len(file.Bytes) == 0 || len(file.Bytes) > MaximumTelegramStickerSize {
		return ErrTelegramStickerDownloadTooLarge
	}
	return nil
}
