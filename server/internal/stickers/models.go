package stickers

import (
	"errors"
	"time"
)

var (
	ErrUnavailable                      = errors.New("sticker service unavailable")
	ErrInvalidInput                     = errors.New("invalid sticker input")
	ErrNotFound                         = errors.New("sticker resource not found")
	ErrForbidden                        = errors.New("sticker operation forbidden")
	ErrConflict                         = errors.New("sticker operation conflict")
	ErrRateLimited                      = errors.New("sticker operation rate limited")
	ErrTelegramRelayNotConfigured       = errors.New("telegram sticker relay is not configured")
	ErrTelegramProviderUnavailable      = errors.New("telegram sticker provider unavailable")
	ErrTelegramProviderUnauthorized     = errors.New("telegram sticker provider unauthorized")
	ErrTelegramProviderRateLimited      = errors.New("telegram sticker provider rate limited")
	ErrTelegramProviderTimeout          = errors.New("telegram sticker provider timeout")
	ErrTelegramStickerSetNotFound       = errors.New("telegram sticker set not found")
	ErrTelegramStickerFormatUnsupported = errors.New("telegram sticker format unsupported")
	ErrTelegramStickerDownloadTooLarge  = errors.New("telegram sticker download too large")
	ErrTelegramStickerDownloadInvalid   = errors.New("telegram sticker download invalid")
)

const (
	MaximumCustomStickers              = 500
	MaximumCustomStickerBatch          = 100
	MaximumStickerPacks                = 64
	MaximumTelegramPackItems           = 120
	MaximumTelegramStickerSize         = 10 * 1024 * 1024
	MaximumTelegramStaticStickerSize   = 512 * 1024
	MaximumTelegramAnimatedStickerSize = 64 * 1024
	MaximumTelegramVideoStickerSize    = 256 * 1024
)

type CustomSticker struct {
	ID        string    `json:"id"`
	MediaID   string    `json:"mediaId"`
	MIMEType  string    `json:"mimeType"`
	Width     int       `json:"width"`
	Height    int       `json:"height"`
	SizeBytes int64     `json:"sizeBytes"`
	SortOrder int       `json:"sortOrder"`
	CreatedAt time.Time `json:"createdAt"`
}

type CreateCustomStickerInput struct {
	MediaID string `json:"mediaId"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
}

type DeleteCustomStickersInput struct {
	StickerIDs []string `json:"stickerIds"`
}

type ReorderCustomStickersInput struct {
	StickerIDs []string `json:"stickerIds"`
}

type StickerItem struct {
	ID                 string `json:"id"`
	MediaID            string `json:"mediaId"`
	Emoji              string `json:"emoji"`
	MIMEType           string `json:"mimeType"`
	Width              int    `json:"width"`
	Height             int    `json:"height"`
	SizeBytes          int64  `json:"sizeBytes"`
	SortOrder          int    `json:"sortOrder"`
	SourceFileUniqueID string `json:"-"`
}

type StickerPack struct {
	ID                      string        `json:"id"`
	SetName                 string        `json:"setName"`
	Title                   string        `json:"title"`
	CoverMediaID            string        `json:"coverMediaId,omitempty"`
	SupportedStickerCount   int           `json:"supportedStickerCount"`
	UnsupportedStickerCount int           `json:"unsupportedStickerCount"`
	SortOrder               int           `json:"sortOrder"`
	Items                   []StickerItem `json:"items"`
	UpdatedAt               time.Time     `json:"updatedAt"`
}

type TelegramSticker struct {
	FileID       string
	FileUniqueID string
	Emoji        string
	Width        int
	Height       int
	FileSize     int64
	IsAnimated   bool
	IsVideo      bool
}

type TelegramStickerSet struct {
	Name     string
	Title    string
	Stickers []TelegramSticker
}

type TelegramFile struct {
	Bytes    []byte
	MIMEType string
	FileName string
}
