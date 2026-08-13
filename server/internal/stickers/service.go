package stickers

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/media"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	telegramImportWindow = time.Hour
	telegramImportLimit  = 10
	telegramCacheTTL     = 24 * time.Hour
)

var setNamePattern = regexp.MustCompile(`^[A-Za-z0-9_]{1,64}$`)

type ManagedMediaImporter interface {
	ImportManagedSticker(ctx context.Context, input media.ManagedStickerInput) (media.MediaObject, error)
}

type Service struct {
	pool     *pgxpool.Pool
	provider TelegramProvider
	media    ManagedMediaImporter
	now      func() time.Time
	importMu sync.Mutex
}

type Config struct {
	Pool     *pgxpool.Pool
	Provider TelegramProvider
	Media    ManagedMediaImporter
	Now      func() time.Time
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Service{pool: config.Pool, provider: config.Provider, media: config.Media, now: now}, nil
}

func normalizeSetName(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if !setNamePattern.MatchString(value) {
		return "", ErrInvalidInput
	}
	return value, nil
}

func (service *Service) ListCustomStickers(ctx context.Context, principal account.Principal) ([]CustomSticker, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT id,media_id,mime_type,width,height,size_bytes,sort_order,created_at
		FROM custom_stickers
		WHERE owner_user_id=$1 AND deleted_at IS NULL
		ORDER BY sort_order,created_at,id
	`, principal.UserID)
	if err != nil {
		return nil, fmt.Errorf("list custom stickers: %w", err)
	}
	defer rows.Close()
	items := make([]CustomSticker, 0)
	for rows.Next() {
		var item CustomSticker
		if err := rows.Scan(&item.ID, &item.MediaID, &item.MIMEType, &item.Width, &item.Height, &item.SizeBytes, &item.SortOrder, &item.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan custom sticker: %w", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate custom stickers: %w", err)
	}
	return items, nil
}

func (service *Service) CreateCustomSticker(ctx context.Context, principal account.Principal, input CreateCustomStickerInput) (CustomSticker, error) {
	mediaID, err := uuid.Parse(strings.TrimSpace(input.MediaID))
	if err != nil || input.Width < 1 || input.Width > 4096 || input.Height < 1 || input.Height > 4096 {
		return CustomSticker{}, ErrInvalidInput
	}
	var mimeType string
	var sizeBytes int64
	if err := service.pool.QueryRow(ctx, `
		SELECT m.mime_type,m.size_bytes
		FROM media_objects m
		WHERE m.id=$1
		  AND m.purpose='STICKER'
		  AND m.status='READY'
		  AND m.deleted_at IS NULL
		  AND (
			m.owner_user_id=$2
			OR EXISTS(
				SELECT 1
				FROM message_media mm
				JOIN messages msg ON msg.id=mm.message_id
				  AND msg.type='STICKER'
				  AND msg.deleted_at IS NULL
				  AND msg.recalled_at IS NULL
				JOIN conversation_members cm ON cm.conversation_id=msg.conversation_id
				  AND cm.user_id=$2
				  AND cm.status='ACTIVE'
				LEFT JOIN message_local_deletions ld ON ld.message_id=msg.id AND ld.user_id=$2
				WHERE mm.media_id=m.id
				  AND mm.role='PRIMARY'
				  AND ld.message_id IS NULL
			)
		  )
	`, mediaID, principal.UserID).Scan(&mimeType, &sizeBytes); errors.Is(err, pgx.ErrNoRows) {
		return CustomSticker{}, ErrForbidden
	} else if err != nil {
		return CustomSticker{}, fmt.Errorf("authorize custom sticker media: %w", err)
	}
	switch mimeType {
	case "image/png", "image/webp", "image/gif", "video/mp4", "video/webm":
	case "application/x-tgsticker":
		if sizeBytes > MaximumTelegramAnimatedStickerSize {
			return CustomSticker{}, ErrInvalidInput
		}
	default:
		return CustomSticker{}, ErrInvalidInput
	}

	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return CustomSticker{}, fmt.Errorf("begin create custom sticker: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "custom-stickers:"+principal.UserID.String()); err != nil {
		return CustomSticker{}, fmt.Errorf("lock custom sticker library: %w", err)
	}
	var count int
	var nextOrder int
	if err := tx.QueryRow(ctx, `
		SELECT count(*),COALESCE(max(sort_order)+1,0)
		FROM custom_stickers
		WHERE owner_user_id=$1 AND deleted_at IS NULL
	`, principal.UserID).Scan(&count, &nextOrder); err != nil {
		return CustomSticker{}, fmt.Errorf("load custom sticker quota: %w", err)
	}
	if count >= MaximumCustomStickers {
		return CustomSticker{}, ErrConflict
	}
	var item CustomSticker
	if err := tx.QueryRow(ctx, `
		INSERT INTO custom_stickers(owner_user_id,media_id,mime_type,width,height,size_bytes,sort_order)
		VALUES($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT(owner_user_id,media_id) DO UPDATE SET
			mime_type=EXCLUDED.mime_type,
			width=EXCLUDED.width,
			height=EXCLUDED.height,
			size_bytes=EXCLUDED.size_bytes,
			sort_order=CASE WHEN custom_stickers.deleted_at IS NOT NULL THEN EXCLUDED.sort_order ELSE custom_stickers.sort_order END,
			deleted_at=NULL
		RETURNING id,media_id,mime_type,width,height,size_bytes,sort_order,created_at
	`, principal.UserID, mediaID, mimeType, input.Width, input.Height, sizeBytes, nextOrder).Scan(
		&item.ID, &item.MediaID, &item.MIMEType, &item.Width, &item.Height, &item.SizeBytes, &item.SortOrder, &item.CreatedAt,
	); err != nil {
		return CustomSticker{}, fmt.Errorf("create custom sticker: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomSticker{}, fmt.Errorf("commit custom sticker: %w", err)
	}
	return item, nil
}

func (service *Service) DeleteCustomStickers(ctx context.Context, principal account.Principal, input DeleteCustomStickersInput) (int, error) {
	ids, err := parseStickerIDs(input.StickerIDs)
	if err != nil {
		return 0, err
	}
	result, err := service.pool.Exec(ctx, `
		UPDATE custom_stickers
		SET deleted_at=$3
		WHERE owner_user_id=$1 AND id=ANY($2::uuid[]) AND deleted_at IS NULL
	`, principal.UserID, ids, service.now().UTC())
	if err != nil {
		return 0, fmt.Errorf("delete custom stickers: %w", err)
	}
	if int(result.RowsAffected()) != len(ids) {
		return 0, ErrNotFound
	}
	return len(ids), nil
}

func (service *Service) ReorderCustomStickers(ctx context.Context, principal account.Principal, input ReorderCustomStickersInput) error {
	ids, err := parseStickerIDs(input.StickerIDs)
	if err != nil {
		return err
	}
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return fmt.Errorf("begin reorder custom stickers: %w", err)
	}
	defer tx.Rollback(ctx)
	var count int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM custom_stickers WHERE owner_user_id=$1 AND deleted_at IS NULL`, principal.UserID).Scan(&count); err != nil {
		return fmt.Errorf("count custom stickers: %w", err)
	}
	if count != len(ids) {
		return ErrConflict
	}
	for order, id := range ids {
		result, err := tx.Exec(ctx, `
			UPDATE custom_stickers SET sort_order=$3
			WHERE owner_user_id=$1 AND id=$2 AND deleted_at IS NULL
		`, principal.UserID, id, order)
		if err != nil {
			return fmt.Errorf("reorder custom sticker: %w", err)
		}
		if result.RowsAffected() != 1 {
			return ErrNotFound
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit custom sticker reorder: %w", err)
	}
	return nil
}

func parseStickerIDs(raw []string) ([]uuid.UUID, error) {
	if len(raw) == 0 || len(raw) > MaximumCustomStickerBatch {
		return nil, ErrInvalidInput
	}
	seen := make(map[uuid.UUID]struct{}, len(raw))
	ids := make([]uuid.UUID, 0, len(raw))
	for _, value := range raw {
		id, err := uuid.Parse(strings.TrimSpace(value))
		if err != nil || id == uuid.Nil {
			return nil, ErrInvalidInput
		}
		if _, exists := seen[id]; exists {
			return nil, ErrInvalidInput
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	return ids, nil
}

func (service *Service) ListStickerPacks(ctx context.Context, principal account.Principal) ([]StickerPack, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT p.id,p.set_name,p.title,COALESCE(p.cover_media_id::text,''),
		       p.supported_sticker_count,p.unsupported_sticker_count,usp.sort_order,p.cache_refreshed_at,
		       COALESCE(i.id::text,''),COALESCE(i.media_id::text,''),COALESCE(i.emoji,''),
		       COALESCE(i.mime_type,''),COALESCE(i.width,0),COALESCE(i.height,0),COALESCE(i.size_bytes,0),COALESCE(i.sort_order,0),COALESCE(i.source_file_unique_id,'')
		FROM user_sticker_packs usp
		JOIN telegram_sticker_packs p ON p.id=usp.pack_id
		LEFT JOIN telegram_sticker_items i ON i.pack_id=p.id
		WHERE usp.user_id=$1
		ORDER BY usp.sort_order,usp.created_at,p.id,i.sort_order,i.id
	`, principal.UserID)
	if err != nil {
		return nil, fmt.Errorf("list sticker packs: %w", err)
	}
	defer rows.Close()
	packs := make([]StickerPack, 0)
	indexByID := make(map[string]int)
	for rows.Next() {
		var packID, itemID, mediaID, emoji, mimeType, sourceUniqueID string
		var pack StickerPack
		var item StickerItem
		if err := rows.Scan(
			&packID, &pack.SetName, &pack.Title, &pack.CoverMediaID,
			&pack.SupportedStickerCount, &pack.UnsupportedStickerCount, &pack.SortOrder, &pack.UpdatedAt,
			&itemID, &mediaID, &emoji, &mimeType, &item.Width, &item.Height, &item.SizeBytes, &item.SortOrder, &sourceUniqueID,
		); err != nil {
			return nil, fmt.Errorf("scan sticker pack: %w", err)
		}
		position, exists := indexByID[packID]
		if !exists {
			pack.ID = packID
			pack.Items = make([]StickerItem, 0, pack.SupportedStickerCount)
			packs = append(packs, pack)
			position = len(packs) - 1
			indexByID[packID] = position
		}
		if itemID != "" {
			item.ID = itemID
			item.MediaID = mediaID
			item.Emoji = emoji
			item.MIMEType = mimeType
			item.SourceFileUniqueID = sourceUniqueID
			packs[position].Items = append(packs[position].Items, item)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate sticker packs: %w", err)
	}
	return packs, nil
}

func (service *Service) ImportTelegramPack(ctx context.Context, principal account.Principal, rawSetName string) (StickerPack, error) {
	setName, err := normalizeSetName(rawSetName)
	if err != nil {
		return StickerPack{}, err
	}
	service.importMu.Lock()
	defer service.importMu.Unlock()

	if cached, fresh, err := service.cachedPack(ctx, principal, setName); err != nil {
		return StickerPack{}, err
	} else if fresh {
		return cached, nil
	}
	if service.provider == nil || service.media == nil {
		return StickerPack{}, ErrTelegramRelayNotConfigured
	}
	if err := service.consumeImportRate(ctx, principal.UserID); err != nil {
		return StickerPack{}, err
	}
	set, err := service.provider.GetStickerSet(ctx, setName)
	if err != nil {
		return StickerPack{}, err
	}
	if len(set.Stickers) == 0 || len(set.Stickers) > MaximumTelegramPackItems {
		return StickerPack{}, ErrInvalidInput
	}
	type preparedItem struct {
		SourceFileID       string
		SourceFileUniqueID string
		MediaID            uuid.UUID
		Emoji              string
		MIMEType           string
		Width              int
		Height             int
		SizeBytes          int64
	}
	prepared := make([]preparedItem, 0, len(set.Stickers))
	unsupported := 0
	tooLarge := 0
	for _, source := range set.Stickers {
		maxSourceBytes := telegramStickerMaximumSize(source)
		if maxSourceBytes == 0 {
			unsupported++
			continue
		}
		if source.FileSize > maxSourceBytes {
			unsupported++
			tooLarge++
			continue
		}
		if cached, ok, cacheErr := service.lookupCachedTelegramAsset(ctx, source.FileUniqueID); cacheErr != nil {
			return StickerPack{}, cacheErr
		} else if ok && cached.SizeBytes <= maxSourceBytes && telegramStickerMIMEMatchesSource(source, cached.MIMEType) {
			prepared = append(prepared, preparedItem{
				SourceFileID: source.FileID, SourceFileUniqueID: source.FileUniqueID,
				MediaID: cached.MediaID, Emoji: source.Emoji, MIMEType: cached.MIMEType,
				Width: source.Width, Height: source.Height, SizeBytes: cached.SizeBytes,
			})
			continue
		}
		file, downloadErr := service.provider.DownloadSticker(ctx, source.FileID, MaximumTelegramStickerSize)
		if downloadErr != nil {
			if errors.Is(downloadErr, ErrTelegramStickerDownloadTooLarge) {
				unsupported++
				tooLarge++
				continue
			}
			if errors.Is(downloadErr, ErrTelegramStickerDownloadInvalid) {
				unsupported++
				continue
			}
			return StickerPack{}, downloadErr
		}
		file, normalizeErr := normalizeTelegramStickerFile(source, file)
		if normalizeErr != nil {
			if errors.Is(normalizeErr, ErrTelegramStickerDownloadTooLarge) {
				unsupported++
				tooLarge++
				continue
			}
			if errors.Is(normalizeErr, ErrTelegramStickerFormatUnsupported) || errors.Is(normalizeErr, ErrTelegramStickerDownloadInvalid) {
				unsupported++
				continue
			}
			return StickerPack{}, normalizeErr
		}
		mediaObject, importErr := service.media.ImportManagedSticker(ctx, media.ManagedStickerInput{
			FileName: file.FileName,
			MIMEType: file.MIMEType,
			Bytes:    file.Bytes,
		})
		if importErr != nil {
			return StickerPack{}, importErr
		}
		mediaID := uuid.MustParse(mediaObject.ID)
		prepared = append(prepared, preparedItem{
			SourceFileID: source.FileID, SourceFileUniqueID: source.FileUniqueID,
			MediaID: mediaID, Emoji: source.Emoji, MIMEType: mediaObject.MIMEType,
			Width: source.Width, Height: source.Height, SizeBytes: mediaObject.SizeBytes,
		})
	}
	if len(prepared) == 0 {
		if unsupported > 0 && tooLarge == unsupported {
			return StickerPack{}, ErrTelegramStickerDownloadTooLarge
		}
		return StickerPack{}, ErrTelegramStickerFormatUnsupported
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return StickerPack{}, fmt.Errorf("begin telegram sticker import: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "telegram-sticker-pack:"+strings.ToLower(setName)); err != nil {
		return StickerPack{}, fmt.Errorf("lock telegram sticker pack: %w", err)
	}
	var packID uuid.UUID
	coverMediaID := prepared[0].MediaID
	if err := tx.QueryRow(ctx, `
		INSERT INTO telegram_sticker_packs(
			set_name,title,source_identifier,cover_media_id,supported_sticker_count,unsupported_sticker_count,source_updated_at,cache_refreshed_at
		)
		VALUES($1,$2,$1,$3,$4,$5,$6,$6)
		ON CONFLICT(set_name) DO UPDATE SET
			title=EXCLUDED.title,
			cover_media_id=EXCLUDED.cover_media_id,
			supported_sticker_count=EXCLUDED.supported_sticker_count,
			unsupported_sticker_count=EXCLUDED.unsupported_sticker_count,
			source_updated_at=EXCLUDED.source_updated_at,
			cache_refreshed_at=EXCLUDED.cache_refreshed_at
		RETURNING id
	`, set.Name, set.Title, coverMediaID, len(prepared), unsupported, now).Scan(&packID); err != nil {
		return StickerPack{}, fmt.Errorf("upsert telegram sticker pack: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM telegram_sticker_items WHERE pack_id=$1`, packID); err != nil {
		return StickerPack{}, fmt.Errorf("replace telegram sticker items: %w", err)
	}
	for order, item := range prepared {
		if _, err := tx.Exec(ctx, `
			INSERT INTO telegram_sticker_items(
				pack_id,source_file_id,source_file_unique_id,media_id,emoji,mime_type,width,height,size_bytes,sort_order
			)
			VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		`, packID, item.SourceFileID, item.SourceFileUniqueID, item.MediaID, item.Emoji, item.MIMEType, item.Width, item.Height, item.SizeBytes, order); err != nil {
			return StickerPack{}, fmt.Errorf("insert telegram sticker item: %w", err)
		}
	}
	if err := subscribePackTx(ctx, tx, principal.UserID, packID); err != nil {
		return StickerPack{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return StickerPack{}, fmt.Errorf("commit telegram sticker import: %w", err)
	}
	return service.getPackForUser(ctx, principal.UserID, setName)
}

func (service *Service) CleanupUnusedPacks(ctx context.Context, limit int, minimumAge time.Duration) (int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}
	if minimumAge < 24*time.Hour {
		minimumAge = 30 * 24 * time.Hour
	}
	cutoff := service.now().UTC().Add(-minimumAge)
	rows, err := service.pool.Query(ctx, `
		SELECT p.id
		FROM telegram_sticker_packs p
		WHERE p.cache_refreshed_at <= $1
		  AND NOT EXISTS(SELECT 1 FROM user_sticker_packs usp WHERE usp.pack_id=p.id)
		ORDER BY p.cache_refreshed_at,p.id
		LIMIT $2
	`, cutoff, limit)
	if err != nil {
		return 0, fmt.Errorf("list unused sticker packs: %w", err)
	}
	var packIDs []uuid.UUID
	for rows.Next() {
		var packID uuid.UUID
		if err := rows.Scan(&packID); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan unused sticker pack: %w", err)
		}
		packIDs = append(packIDs, packID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, fmt.Errorf("iterate unused sticker packs: %w", err)
	}
	rows.Close()

	removed := 0
	for _, packID := range packIDs {
		tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
		if err != nil {
			return removed, fmt.Errorf("begin unused sticker pack cleanup: %w", err)
		}
		var lockedID uuid.UUID
		err = tx.QueryRow(ctx, `
			SELECT p.id
			FROM telegram_sticker_packs p
			WHERE p.id=$1 AND p.cache_refreshed_at <= $2
			  AND NOT EXISTS(SELECT 1 FROM user_sticker_packs usp WHERE usp.pack_id=p.id)
			FOR UPDATE OF p
		`, packID, cutoff).Scan(&lockedID)
		if errors.Is(err, pgx.ErrNoRows) {
			_ = tx.Rollback(ctx)
			continue
		}
		if err != nil {
			_ = tx.Rollback(ctx)
			return removed, fmt.Errorf("lock unused sticker pack: %w", err)
		}
		if _, err := tx.Exec(ctx, `DELETE FROM telegram_sticker_packs WHERE id=$1`, lockedID); err != nil {
			_ = tx.Rollback(ctx)
			return removed, fmt.Errorf("delete unused sticker pack: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return removed, fmt.Errorf("commit unused sticker pack cleanup: %w", err)
		}
		removed++
	}
	return removed, nil
}

func (service *Service) RemoveStickerPack(ctx context.Context, principal account.Principal, packID uuid.UUID) error {
	if packID == uuid.Nil {
		return ErrInvalidInput
	}
	result, err := service.pool.Exec(ctx, `DELETE FROM user_sticker_packs WHERE user_id=$1 AND pack_id=$2`, principal.UserID, packID)
	if err != nil {
		return fmt.Errorf("remove sticker pack: %w", err)
	}
	if result.RowsAffected() != 1 {
		return ErrNotFound
	}
	return nil
}

func (service *Service) cachedPack(ctx context.Context, principal account.Principal, setName string) (StickerPack, bool, error) {
	var packID uuid.UUID
	var refreshed time.Time
	var itemCount int
	var unsupportedCount int
	err := service.pool.QueryRow(ctx, `
		SELECT p.id,p.cache_refreshed_at,count(i.id),p.unsupported_sticker_count
		FROM telegram_sticker_packs p
		LEFT JOIN telegram_sticker_items i ON i.pack_id=p.id
		WHERE lower(p.set_name)=lower($1)
		GROUP BY p.id,p.cache_refreshed_at,p.unsupported_sticker_count
	`, setName).Scan(&packID, &refreshed, &itemCount, &unsupportedCount)
	if errors.Is(err, pgx.ErrNoRows) {
		return StickerPack{}, false, nil
	}
	if err != nil {
		return StickerPack{}, false, fmt.Errorf("load telegram sticker cache: %w", err)
	}
	if itemCount == 0 || unsupportedCount > 0 || service.now().UTC().Sub(refreshed) > telegramCacheTTL {
		return StickerPack{}, false, nil
	}
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return StickerPack{}, false, fmt.Errorf("begin cached pack subscription: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := subscribePackTx(ctx, tx, principal.UserID, packID); err != nil {
		return StickerPack{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return StickerPack{}, false, fmt.Errorf("commit cached pack subscription: %w", err)
	}
	pack, err := service.getPackForUser(ctx, principal.UserID, setName)
	return pack, err == nil, err
}

func subscribePackTx(ctx context.Context, tx pgx.Tx, userID, packID uuid.UUID) error {
	var count int
	var nextOrder int
	if err := tx.QueryRow(ctx, `
		SELECT count(*),COALESCE(max(sort_order)+1,0)
		FROM user_sticker_packs WHERE user_id=$1
	`, userID).Scan(&count, &nextOrder); err != nil {
		return fmt.Errorf("load sticker pack subscription quota: %w", err)
	}
	if count >= MaximumStickerPacks {
		var already bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM user_sticker_packs WHERE user_id=$1 AND pack_id=$2)`, userID, packID).Scan(&already); err != nil {
			return fmt.Errorf("check sticker pack subscription: %w", err)
		}
		if !already {
			return ErrConflict
		}
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO user_sticker_packs(user_id,pack_id,sort_order)
		VALUES($1,$2,$3)
		ON CONFLICT(user_id,pack_id) DO NOTHING
	`, userID, packID, nextOrder); err != nil {
		return fmt.Errorf("subscribe sticker pack: %w", err)
	}
	return nil
}

type cachedTelegramAsset struct {
	MediaID   uuid.UUID
	MIMEType  string
	SizeBytes int64
}

func (service *Service) lookupCachedTelegramAsset(ctx context.Context, sourceUniqueID string) (cachedTelegramAsset, bool, error) {
	var result cachedTelegramAsset
	err := service.pool.QueryRow(ctx, `
		SELECT i.media_id,i.mime_type,i.size_bytes
		FROM telegram_sticker_items i
		JOIN media_objects m ON m.id=i.media_id AND m.status='READY' AND m.deleted_at IS NULL
		WHERE i.source_file_unique_id=$1
		ORDER BY i.created_at DESC
		LIMIT 1
	`, sourceUniqueID).Scan(&result.MediaID, &result.MIMEType, &result.SizeBytes)
	if errors.Is(err, pgx.ErrNoRows) {
		return cachedTelegramAsset{}, false, nil
	}
	if err != nil {
		return cachedTelegramAsset{}, false, fmt.Errorf("lookup telegram sticker cache: %w", err)
	}
	return result, true, nil
}

func (service *Service) getPackForUser(ctx context.Context, userID uuid.UUID, setName string) (StickerPack, error) {
	packs, err := service.ListStickerPacks(ctx, account.Principal{UserID: userID})
	if err != nil {
		return StickerPack{}, err
	}
	for _, pack := range packs {
		if strings.EqualFold(pack.SetName, setName) {
			return pack, nil
		}
	}
	return StickerPack{}, ErrNotFound
}

func (service *Service) consumeImportRate(ctx context.Context, userID uuid.UUID) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin sticker rate limit: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "telegram-import:"+userID.String()); err != nil {
		return fmt.Errorf("lock sticker rate limit: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM sticker_rate_events WHERE created_at < $1`, now.Add(-24*time.Hour)); err != nil {
		return fmt.Errorf("cleanup sticker rate events: %w", err)
	}
	var count int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM sticker_rate_events
		WHERE user_id=$1 AND scope='TELEGRAM_IMPORT' AND created_at>$2
	`, userID, now.Add(-telegramImportWindow)).Scan(&count); err != nil {
		return fmt.Errorf("load sticker rate events: %w", err)
	}
	if count >= telegramImportLimit {
		return ErrRateLimited
	}
	if _, err := tx.Exec(ctx, `INSERT INTO sticker_rate_events(user_id,scope,created_at) VALUES($1,'TELEGRAM_IMPORT',$2)`, userID, now); err != nil {
		return fmt.Errorf("record sticker rate event: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit sticker rate event: %w", err)
	}
	return nil
}

func sortCustomStickers(items []CustomSticker) {
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].SortOrder != items[j].SortOrder {
			return items[i].SortOrder < items[j].SortOrder
		}
		return items[i].CreatedAt.Before(items[j].CreatedAt)
	})
}
