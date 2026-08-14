package stickers

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
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

func (provider *TelegramBotProvider) GetMe(ctx context.Context) (TelegramBotInfo, error) {
	var result struct {
		ID       int64  `json:"id"`
		IsBot    bool   `json:"is_bot"`
		Username string `json:"username"`
	}
	if err := provider.call(ctx, "getMe", nil, &result); err != nil {
		return TelegramBotInfo{}, err
	}
	if result.ID <= 0 || !result.IsBot {
		return TelegramBotInfo{}, ErrTelegramProviderUnavailable
	}
	return TelegramBotInfo{ID: result.ID, Username: strings.TrimSpace(result.Username)}, nil
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
		return TelegramFile{}, classifyTelegramTransportError(err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return TelegramFile{}, ErrTelegramProviderUnavailable
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBytes+1))
	if err != nil {
		return TelegramFile{}, classifyTelegramTransportError(err)
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
		return classifyTelegramTransportError(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024))
	if err != nil {
		return classifyTelegramTransportError(err)
	}
	var base struct {
		OK          bool            `json:"ok"`
		Result      json.RawMessage `json:"result"`
		ErrorCode   int             `json:"error_code"`
		Description string          `json:"description"`
	}
	if err := json.Unmarshal(body, &base); err != nil {
		return ErrTelegramProviderUnavailable
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 || !base.OK {
		return classifyTelegramAPIError(method, response.StatusCode, base.ErrorCode, base.Description)
	}
	if err := json.Unmarshal(base.Result, result); err != nil {
		return ErrTelegramProviderUnavailable
	}
	return nil
}

func classifyTelegramTransportError(err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return ErrTelegramProviderTimeout
	}
	return ErrTelegramProviderUnavailable
}

func classifyTelegramAPIError(method string, statusCode int, errorCode int, description string) error {
	description = strings.ToUpper(strings.TrimSpace(description))
	switch {
	case method == "getStickerSet" &&
		(statusCode == http.StatusBadRequest || errorCode == http.StatusBadRequest) &&
		strings.Contains(description, "STICKERSET_INVALID"):
		return ErrTelegramStickerSetNotFound
	case statusCode == http.StatusUnauthorized || errorCode == http.StatusUnauthorized:
		return ErrTelegramProviderUnauthorized
	case statusCode == http.StatusTooManyRequests || errorCode == http.StatusTooManyRequests:
		return ErrTelegramProviderRateLimited
	default:
		return ErrTelegramProviderUnavailable
	}
}

func sniffTelegramStickerMIME(data []byte) string {
	if len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		return "image/webp"
	}
	if len(data) >= 8 && bytes.Equal(data[:8], []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}) {
		return "image/png"
	}
	if len(data) >= 2 && data[0] == 0x1F && data[1] == 0x8B {
		return "application/x-tgsticker"
	}
	if len(data) >= 4 && bytes.Equal(data[:4], []byte{0x1A, 0x45, 0xDF, 0xA3}) {
		probe := data
		if len(probe) > 4096 {
			probe = probe[:4096]
		}
		if bytes.Contains(bytes.ToLower(probe), []byte("webm")) {
			return "video/webm"
		}
	}
	return "application/octet-stream"
}

func telegramStickerMaximumSize(source TelegramSticker) int64 {
	if source.IsAnimated && !source.IsVideo {
		return MaximumTelegramAnimatedStickerSize
	}
	if source.IsVideo && !source.IsAnimated {
		return MaximumTelegramVideoStickerSize
	}
	if !source.IsAnimated && !source.IsVideo {
		return MaximumTelegramStaticStickerSize
	}
	return 0
}

func telegramStickerMIMEMatchesSource(source TelegramSticker, mimeType string) bool {
	normalized := strings.ToLower(strings.TrimSpace(strings.Split(mimeType, ";")[0]))
	if source.IsAnimated && !source.IsVideo {
		return normalized == "application/x-tgsticker"
	}
	if source.IsVideo && !source.IsAnimated {
		return normalized == "video/webm"
	}
	if !source.IsAnimated && !source.IsVideo {
		return normalized == "image/webp" || normalized == "image/png"
	}
	return false
}

func normalizeTelegramStickerFile(source TelegramSticker, file TelegramFile) (TelegramFile, error) {
	if len(file.Bytes) == 0 || source.IsAnimated && source.IsVideo {
		return TelegramFile{}, ErrTelegramStickerDownloadInvalid
	}
	maxBytes := telegramStickerMaximumSize(source)
	if maxBytes == 0 {
		return TelegramFile{}, ErrTelegramStickerFormatUnsupported
	}
	if int64(len(file.Bytes)) > maxBytes {
		return TelegramFile{}, ErrTelegramStickerDownloadTooLarge
	}

	detected := sniffTelegramStickerMIME(file.Bytes)
	switch {
	case source.IsAnimated:
		if detected != "application/x-tgsticker" || !validTelegramTGS(file.Bytes) {
			return TelegramFile{}, fmt.Errorf("%w: invalid TGS sticker", ErrTelegramStickerFormatUnsupported)
		}
		file.MIMEType = "application/x-tgsticker"
		if path.Ext(file.FileName) == "" {
			file.FileName += ".tgs"
		}
	case source.IsVideo:
		if detected != "video/webm" {
			return TelegramFile{}, fmt.Errorf("%w: invalid WebM sticker", ErrTelegramStickerFormatUnsupported)
		}
		file.MIMEType = "video/webm"
		if path.Ext(file.FileName) == "" {
			file.FileName += ".webm"
		}
	default:
		if detected != "image/webp" && detected != "image/png" {
			return TelegramFile{}, fmt.Errorf("%w: invalid static sticker", ErrTelegramStickerFormatUnsupported)
		}
		file.MIMEType = detected
	}
	return file, nil
}

func validateTelegramStickerFile(source TelegramSticker, file TelegramFile) error {
	_, err := normalizeTelegramStickerFile(source, file)
	return err
}

func validateStaticTelegramSticker(file TelegramFile) error {
	return validateTelegramStickerFile(TelegramSticker{}, file)
}

func validTelegramTGS(data []byte) bool {
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return false
	}
	defer reader.Close()
	const maxDecodedTGSBytes = 4 * 1024 * 1024
	decoded, err := io.ReadAll(io.LimitReader(reader, maxDecodedTGSBytes+1))
	if err != nil || len(decoded) == 0 || len(decoded) > maxDecodedTGSBytes {
		return false
	}
	var document struct {
		Version   string  `json:"v"`
		FrameRate float64 `json:"fr"`
		InPoint   float64 `json:"ip"`
		OutPoint  float64 `json:"op"`
		Width     int     `json:"w"`
		Height    int     `json:"h"`
	}
	if err := json.Unmarshal(decoded, &document); err != nil {
		return false
	}
	return strings.TrimSpace(document.Version) != "" &&
		document.FrameRate > 0 &&
		document.OutPoint > document.InPoint &&
		document.Width > 0 && document.Width <= 512 &&
		document.Height > 0 && document.Height <= 512
}
