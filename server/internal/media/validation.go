package media

import (
	"crypto/rand"
	"encoding/hex"
	"mime"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	maxImageBytes   int64 = 25 * 1024 * 1024
	maxGIFBytes     int64 = 50 * 1024 * 1024
	maxVoiceBytes   int64 = 25 * 1024 * 1024
	maxVideoBytes   int64 = 2 * 1024 * 1024 * 1024
	maxStickerBytes int64 = 10 * 1024 * 1024
	maxFileBytes    int64 = 2 * 1024 * 1024 * 1024
)

var sha256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func validateUploadInput(input CreateUploadInput) error {
	name := strings.TrimSpace(input.FileName)
	if name == "" || utf8.RuneCountInString(name) > 255 || strings.ContainsAny(name, "\x00\r\n") {
		return ErrInvalidInput
	}
	if input.Size <= 0 {
		return ErrInvalidInput
	}
	mimeType := strings.ToLower(strings.TrimSpace(strings.Split(input.MIMEType, ";")[0]))
	if _, _, err := mime.ParseMediaType(mimeType); err != nil {
		return ErrInvalidInput
	}
	if !sha256Pattern.MatchString(input.SHA256) {
		return ErrInvalidInput
	}

	var maxBytes int64
	switch input.Purpose {
	case PurposeChatImage, PurposeMomentImage:
		maxBytes = maxImageBytes
		if mimeType != "image/jpeg" && mimeType != "image/png" && mimeType != "image/webp" {
			return ErrInvalidInput
		}
	case PurposeGIF:
		maxBytes = maxGIFBytes
		if mimeType != "image/gif" && mimeType != "image/webp" {
			return ErrInvalidInput
		}
	case PurposeSticker:
		maxBytes = maxStickerBytes
		if mimeType != "image/png" && mimeType != "image/webp" && mimeType != "image/gif" {
			return ErrInvalidInput
		}
	case PurposeChatVoice:
		maxBytes = maxVoiceBytes
		if !strings.HasPrefix(mimeType, "audio/") {
			return ErrInvalidInput
		}
	case PurposeChatVideo, PurposeMomentVideo:
		maxBytes = maxVideoBytes
		switch mimeType {
		case "video/mp4", "video/webm", "video/quicktime", "video/x-matroska":
		default:
			return ErrInvalidInput
		}
	case PurposeChatFile:
		maxBytes = maxFileBytes
	default:
		return ErrInvalidInput
	}
	if input.Size > maxBytes {
		return ErrQuotaExceeded
	}
	return nil
}

func normalizeUploadInput(input CreateUploadInput) CreateUploadInput {
	input.FileName = filepath.Base(strings.TrimSpace(input.FileName))
	input.MIMEType = strings.ToLower(strings.TrimSpace(strings.Split(input.MIMEType, ";")[0]))
	input.SHA256 = strings.ToLower(strings.TrimSpace(input.SHA256))
	return input
}

func newStorageKey(purpose Purpose) (string, error) {
	prefix := strings.ToLower(strings.ReplaceAll(string(purpose), "_", "-"))
	now := time.Now().UTC()
	buffer := make([]byte, 24)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return prefix + "/" + now.Format("2006") + "/" + now.Format("01") + "/" + hex.EncodeToString(buffer), nil
}
