package account

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const (
	MaxProfileAvatarBytes  = 2 * 1024 * 1024
	MaxProfileAvatarWidth  = 2048
	MaxProfileAvatarHeight = 2048
	MaxProfileAvatarPixels = 4 * 1024 * 1024
)

var ErrInvalidAvatar = errors.New("invalid profile avatar")

type ProfileAvatar struct {
	ContentType string
	Bytes       []byte
	UpdatedAt   time.Time
}

func (service *Service) PutProfileAvatar(ctx context.Context, principal Principal, contentType string, image []byte) (time.Time, error) {
	contentType = strings.ToLower(strings.TrimSpace(strings.Split(contentType, ";")[0]))
	if len(image) == 0 || len(image) > MaxProfileAvatarBytes || !validAvatarPayload(contentType, image) {
		return time.Time{}, ErrInvalidAvatar
	}

	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return time.Time{}, fmt.Errorf("begin avatar update: %w", err)
	}
	defer tx.Rollback(ctx)

	var avatarID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO profile_avatars(user_id,content_type,image_bytes,updated_at)
		VALUES ($1,$2,$3,$4)
		ON CONFLICT (user_id) DO UPDATE SET
			content_type=EXCLUDED.content_type,
			image_bytes=EXCLUDED.image_bytes,
			updated_at=EXCLUDED.updated_at
		RETURNING id
	`, principal.UserID, contentType, image, now).Scan(&avatarID); err != nil {
		return time.Time{}, fmt.Errorf("store avatar: %w", err)
	}
	result, err := tx.Exec(ctx, `
		UPDATE users SET avatar_media_id=$2,updated_at=$3
		WHERE id=$1 AND status='ACTIVE'
	`, principal.UserID, avatarID, now)
	if err != nil {
		return time.Time{}, fmt.Errorf("attach avatar: %w", err)
	}
	if result.RowsAffected() != 1 {
		return time.Time{}, ErrNotFound
	}
	if err := tx.Commit(ctx); err != nil {
		return time.Time{}, fmt.Errorf("commit avatar update: %w", err)
	}
	service.audit(ctx, principal.UserID, principal.DeviceID, "PROFILE_AVATAR_UPDATED", `{}`)
	return now, nil
}

func (service *Service) GetProfileAvatar(ctx context.Context, userID uuid.UUID) (ProfileAvatar, error) {
	var result ProfileAvatar
	err := service.pool.QueryRow(ctx, `
		SELECT a.content_type,a.image_bytes,a.updated_at
		FROM profile_avatars a
		JOIN users u ON u.id=a.user_id
		WHERE a.user_id=$1 AND u.status='ACTIVE'
	`, userID).Scan(&result.ContentType, &result.Bytes, &result.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ProfileAvatar{}, ErrNotFound
	}
	if err != nil {
		return ProfileAvatar{}, fmt.Errorf("load avatar: %w", err)
	}
	return result, nil
}

func (service *Service) DeleteProfileAvatar(ctx context.Context, principal Principal) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin avatar delete: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `UPDATE users SET avatar_media_id=NULL,updated_at=$2 WHERE id=$1 AND status='ACTIVE'`, principal.UserID, now); err != nil {
		return fmt.Errorf("detach avatar: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM profile_avatars WHERE user_id=$1`, principal.UserID); err != nil {
		return fmt.Errorf("delete avatar: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit avatar delete: %w", err)
	}
	service.audit(ctx, principal.UserID, principal.DeviceID, "PROFILE_AVATAR_DELETED", `{}`)
	return nil
}

func validAvatarPayload(contentType string, payload []byte) bool {
	width, height, ok := avatarDimensions(contentType, payload)
	if !ok || width < 1 || height < 1 {
		return false
	}
	if width > MaxProfileAvatarWidth || height > MaxProfileAvatarHeight {
		return false
	}
	return int64(width)*int64(height) <= MaxProfileAvatarPixels
}

func avatarDimensions(contentType string, payload []byte) (int, int, bool) {
	switch contentType {
	case "image/jpeg", "image/png":
		config, format, err := image.DecodeConfig(bytes.NewReader(payload))
		if err != nil {
			return 0, 0, false
		}
		expected := strings.TrimPrefix(contentType, "image/")
		if format != expected {
			return 0, 0, false
		}
		return config.Width, config.Height, true
	case "image/webp":
		return webPDimensions(payload)
	default:
		return 0, 0, false
	}
}

func webPDimensions(payload []byte) (int, int, bool) {
	if len(payload) < 20 || string(payload[:4]) != "RIFF" || string(payload[8:12]) != "WEBP" {
		return 0, 0, false
	}
	for offset := 12; offset+8 <= len(payload); {
		chunkType := string(payload[offset : offset+4])
		chunkSize := int(binary.LittleEndian.Uint32(payload[offset+4 : offset+8]))
		dataStart := offset + 8
		dataEnd := dataStart + chunkSize
		if chunkSize < 0 || dataEnd < dataStart || dataEnd > len(payload) {
			return 0, 0, false
		}
		chunk := payload[dataStart:dataEnd]
		switch chunkType {
		case "VP8X":
			if len(chunk) < 10 {
				return 0, 0, false
			}
			width := 1 + int(chunk[4]) + int(chunk[5])<<8 + int(chunk[6])<<16
			height := 1 + int(chunk[7]) + int(chunk[8])<<8 + int(chunk[9])<<16
			return width, height, true
		case "VP8L":
			if len(chunk) < 5 || chunk[0] != 0x2F {
				return 0, 0, false
			}
			bits := uint32(chunk[1]) | uint32(chunk[2])<<8 | uint32(chunk[3])<<16 | uint32(chunk[4])<<24
			width := int(bits&0x3FFF) + 1
			height := int((bits>>14)&0x3FFF) + 1
			return width, height, true
		case "VP8 ":
			if len(chunk) < 10 || chunk[3] != 0x9D || chunk[4] != 0x01 || chunk[5] != 0x2A {
				return 0, 0, false
			}
			width := int(binary.LittleEndian.Uint16(chunk[6:8]) & 0x3FFF)
			height := int(binary.LittleEndian.Uint16(chunk[8:10]) & 0x3FFF)
			return width, height, width > 0 && height > 0
		}
		offset = dataEnd + (chunkSize & 1)
	}
	return 0, 0, false
}
