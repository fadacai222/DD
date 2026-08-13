package moments

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	maximumMomentText      = 2000
	maximumMomentMedia     = 9
	maximumCommentText     = 1000
	defaultFeedLimit       = 30
	maximumFeedLimit       = 50
	maximumVisibilityUsers = 500
)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

type Config struct {
	Pool *pgxpool.Pool
	Now  func() time.Time
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Service{pool: config.Pool, now: now}, nil
}

func (service *Service) Create(ctx context.Context, principal account.Principal, raw CreateInput) (Moment, []uuid.UUID, error) {
	input, mediaIDs, visibilityIDs, err := normalizeCreateInput(raw)
	if err != nil {
		return Moment{}, nil, err
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Moment{}, nil, fmt.Errorf("begin create moment: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := validateMomentMediaTx(ctx, tx, principal.UserID, mediaIDs); err != nil {
		return Moment{}, nil, err
	}
	if err := validateVisibilityTargetsTx(ctx, tx, principal.UserID, visibilityIDs); err != nil {
		return Moment{}, nil, err
	}
	momentID := uuid.New()
	if _, err := tx.Exec(ctx, `
		INSERT INTO moments(id,author_user_id,text,visibility,status,created_at)
		VALUES($1,$2,$3,$4,'ACTIVE',$5)
	`, momentID, principal.UserID, input.Text, input.Visibility, now); err != nil {
		return Moment{}, nil, fmt.Errorf("insert moment: %w", err)
	}
	for index, mediaID := range mediaIDs {
		if _, err := tx.Exec(ctx, `
			INSERT INTO moment_media(moment_id,media_id,sort_order) VALUES($1,$2,$3)
		`, momentID, mediaID, index); err != nil {
			return Moment{}, nil, fmt.Errorf("attach moment media: %w", err)
		}
	}
	mode := ""
	switch input.Visibility {
	case VisibilityPrivate:
		mode = "INCLUDED"
	case VisibilityExclude:
		mode = "EXCLUDED"
	}
	if mode != "" {
		for _, userID := range visibilityIDs {
			if _, err := tx.Exec(ctx, `
				INSERT INTO moment_visibility_users(moment_id,user_id,mode) VALUES($1,$2,$3)
			`, momentID, userID, mode); err != nil {
				return Moment{}, nil, fmt.Errorf("insert moment visibility target: %w", err)
			}
		}
	}
	recipients, err := audienceUserIDsTx(ctx, tx, momentID, principal.UserID)
	if err != nil {
		return Moment{}, nil, err
	}
	recipients = appendUniqueUUID(recipients, principal.UserID)
	if err := insertMomentOutboxTx(ctx, tx, momentID, "MOMENT_CREATED", recipients, now); err != nil {
		return Moment{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Moment{}, nil, fmt.Errorf("commit create moment: %w", err)
	}
	moment, err := service.Get(ctx, principal, momentID)
	if err != nil {
		return Moment{}, nil, err
	}
	return moment, recipients, nil
}

func (service *Service) GetActivitySummary(ctx context.Context, principal account.Principal) (ActivitySummary, error) {
	summary := ActivitySummary{Items: []ActivityItem{}}
	rows, err := service.pool.Query(ctx, `
		WITH visible_activity AS (
		  SELECT activity.id,activity.kind,
		         actor.id AS actor_id,actor.handle_normalized,
		         COALESCE(NULLIF(viewer_contact.remark,''),actor.display_name) AS display_name,
		         activity.moment_id,activity.source_comment_id,
		         COALESCE(mc.text,'') AS comment_text,activity.created_at,activity.read_at
		  FROM moment_activity_notifications activity
		  JOIN moments moment ON moment.id=activity.moment_id AND moment.status='ACTIVE'
		  JOIN users actor ON actor.id=activity.actor_user_id AND actor.status='ACTIVE'
		  LEFT JOIN contacts viewer_contact ON viewer_contact.owner_user_id=$1 AND viewer_contact.contact_user_id=actor.id
		  LEFT JOIN moment_comments mc ON mc.id=activity.source_comment_id AND mc.deleted_at IS NULL
		  WHERE activity.recipient_user_id=$1
		    AND `+momentVisibilitySQL("moment", "$1")+`
		    AND NOT EXISTS(
		      SELECT 1 FROM blocks b
		      WHERE (b.owner_user_id=$1 AND b.blocked_user_id=activity.actor_user_id)
		         OR (b.owner_user_id=activity.actor_user_id AND b.blocked_user_id=$1)
		    )
		    AND (activity.kind <> 'COMMENT' OR mc.id IS NOT NULL)
		)
		SELECT count(*) FILTER (WHERE read_at IS NULL) OVER (),
		       id::text,kind,actor_id::text,handle_normalized,display_name,
		       moment_id::text,source_comment_id::text,comment_text,created_at,(read_at IS NOT NULL)
		FROM visible_activity
		ORDER BY created_at DESC,id DESC
		LIMIT 30
	`, principal.UserID)
	if err != nil {
		return ActivitySummary{}, fmt.Errorf("list recent moment activity: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var item ActivityItem
		if err := rows.Scan(
			&summary.UnreadCount,
			&item.ID,
			&item.Kind,
			&item.Actor.ID,
			&item.Actor.Handle,
			&item.Actor.DisplayName,
			&item.MomentID,
			&item.CommentID,
			&item.CommentText,
			&item.CreatedAt,
			&item.Read,
		); err != nil {
			return ActivitySummary{}, fmt.Errorf("scan recent moment activity: %w", err)
		}
		item.CreatedAt = item.CreatedAt.UTC()
		summary.Items = append(summary.Items, item)
	}
	if err := rows.Err(); err != nil {
		return ActivitySummary{}, fmt.Errorf("iterate recent moment activity: %w", err)
	}
	return summary, nil
}

func (service *Service) MarkActivityRead(ctx context.Context, principal account.Principal) (ActivitySummary, error) {
	now := service.now().UTC()
	if _, err := service.pool.Exec(ctx, `
		UPDATE moment_activity_notifications
		SET read_at=$2
		WHERE recipient_user_id=$1 AND read_at IS NULL
	`, principal.UserID, now); err != nil {
		return ActivitySummary{}, fmt.Errorf("mark moment activity read: %w", err)
	}
	return service.GetActivitySummary(ctx, principal)
}

func (service *Service) ListFeed(ctx context.Context, principal account.Principal, before, authorID *uuid.UUID, limit int) ([]Moment, error) {
	if limit <= 0 {
		limit = defaultFeedLimit
	}
	if limit > maximumFeedLimit {
		return nil, ErrInvalidInput
	}
	var beforeID any
	if before != nil && *before != uuid.Nil {
		beforeID = *before
	}
	var filteredAuthorID any
	if authorID != nil && *authorID != uuid.Nil {
		filteredAuthorID = *authorID
	}
	rows, err := service.pool.Query(ctx, `
		SELECT m.id
		FROM moments m
		WHERE m.status='ACTIVE'
		  AND ($2::uuid IS NULL OR (m.created_at,m.id) < (
		    SELECT cursor.created_at,cursor.id FROM moments cursor WHERE cursor.id=$2::uuid
		  ))
		  AND ($3::uuid IS NULL OR m.author_user_id=$3::uuid)
		  AND `+momentVisibilitySQL("m", "$1")+`
		ORDER BY m.created_at DESC,m.id DESC
		LIMIT $4
	`, principal.UserID, beforeID, filteredAuthorID, limit)
	if err != nil {
		return nil, fmt.Errorf("list moment feed: %w", err)
	}
	defer rows.Close()
	ids := make([]uuid.UUID, 0, limit)
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan moment feed id: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate moment feed: %w", err)
	}
	items := make([]Moment, 0, len(ids))
	for _, id := range ids {
		item, err := service.Get(ctx, principal, id)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				continue
			}
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

func (service *Service) Get(ctx context.Context, principal account.Principal, momentID uuid.UUID) (Moment, error) {
	if momentID == uuid.Nil {
		return Moment{}, ErrNotFound
	}
	var result Moment
	var authorID uuid.UUID
	if err := service.pool.QueryRow(ctx, `
		SELECT m.id::text,m.author_user_id,u.handle_normalized,
		       COALESCE(NULLIF(viewer_author.remark,''),u.display_name),m.text,m.visibility,m.created_at,
		       EXISTS(SELECT 1 FROM moment_likes ml WHERE ml.moment_id=m.id AND ml.user_id=$2)
		FROM moments m
		JOIN users u ON u.id=m.author_user_id AND u.status='ACTIVE'
		LEFT JOIN contacts viewer_author ON viewer_author.owner_user_id=$2 AND viewer_author.contact_user_id=u.id
		WHERE m.id=$1 AND m.status='ACTIVE' AND `+momentVisibilitySQL("m", "$2"), momentID, principal.UserID).Scan(
		&result.ID,
		&authorID,
		&result.Author.Handle,
		&result.Author.DisplayName,
		&result.Text,
		&result.Visibility,
		&result.CreatedAt,
		&result.LikedByMe,
	); errors.Is(err, pgx.ErrNoRows) {
		return Moment{}, ErrNotFound
	} else if err != nil {
		return Moment{}, fmt.Errorf("load moment: %w", err)
	}
	result.Author.ID = authorID.String()
	result.CreatedAt = result.CreatedAt.UTC()

	mediaRows, err := service.pool.Query(ctx, `
		SELECT media_id::text FROM moment_media WHERE moment_id=$1 ORDER BY sort_order
	`, momentID)
	if err != nil {
		return Moment{}, fmt.Errorf("list moment media: %w", err)
	}
	for mediaRows.Next() {
		var mediaID string
		if err := mediaRows.Scan(&mediaID); err != nil {
			mediaRows.Close()
			return Moment{}, fmt.Errorf("scan moment media: %w", err)
		}
		result.MediaIDs = append(result.MediaIDs, mediaID)
	}
	mediaRows.Close()
	if err := mediaRows.Err(); err != nil {
		return Moment{}, fmt.Errorf("iterate moment media: %w", err)
	}

	likeRows, err := service.pool.Query(ctx, `
		SELECT u.id::text,u.handle_normalized,COALESCE(NULLIF(viewer_contact.remark,''),u.display_name)
		FROM moment_likes ml
		JOIN users u ON u.id=ml.user_id AND u.status='ACTIVE'
		LEFT JOIN contacts viewer_contact ON viewer_contact.owner_user_id=$2::uuid AND viewer_contact.contact_user_id=u.id
		WHERE ml.moment_id=$1
		  AND ($2::uuid=$3::uuid OR u.id=$2::uuid OR u.id=$3::uuid OR EXISTS(
		    SELECT 1 FROM contacts c WHERE c.owner_user_id=$2::uuid AND c.contact_user_id=u.id
		  ))
		  AND ($2::uuid=$3::uuid OR NOT EXISTS(
		    SELECT 1 FROM blocks b
		    WHERE (b.owner_user_id=$2::uuid AND b.blocked_user_id=u.id)
		       OR (b.owner_user_id=u.id AND b.blocked_user_id=$2::uuid)
		  ))
		ORDER BY ml.created_at,u.id
	`, momentID, principal.UserID, authorID)
	if err != nil {
		return Moment{}, fmt.Errorf("list moment likes: %w", err)
	}
	for likeRows.Next() {
		var item UserPreview
		if err := likeRows.Scan(&item.ID, &item.Handle, &item.DisplayName); err != nil {
			likeRows.Close()
			return Moment{}, fmt.Errorf("scan moment like: %w", err)
		}
		result.LikeUsers = append(result.LikeUsers, item)
	}
	likeRows.Close()
	if err := likeRows.Err(); err != nil {
		return Moment{}, fmt.Errorf("iterate moment likes: %w", err)
	}

	commentRows, err := service.pool.Query(ctx, `
		SELECT mc.id::text,u.id::text,u.handle_normalized,COALESCE(NULLIF(viewer_contact.remark,''),u.display_name),
		       CASE WHEN mc.reply_to_comment_id IS NOT NULL AND EXISTS(
		         SELECT 1 FROM moment_comments reply
		         JOIN users reply_user ON reply_user.id=reply.author_user_id AND reply_user.status='ACTIVE'
		         WHERE reply.id=mc.reply_to_comment_id AND reply.deleted_at IS NULL
		           AND ($2::uuid=$3::uuid OR reply_user.id=$2::uuid OR reply_user.id=$3::uuid OR EXISTS(
		             SELECT 1 FROM contacts c WHERE c.owner_user_id=$2::uuid AND c.contact_user_id=reply_user.id
		           ))
		           AND ($2::uuid=$3::uuid OR NOT EXISTS(
		             SELECT 1 FROM blocks b WHERE (b.owner_user_id=$2::uuid AND b.blocked_user_id=reply_user.id) OR (b.owner_user_id=reply_user.id AND b.blocked_user_id=$2::uuid)
		           ))
		       ) THEN mc.reply_to_comment_id::text ELSE NULL END,
		       mc.text,mc.created_at
		FROM moment_comments mc
		JOIN users u ON u.id=mc.author_user_id AND u.status='ACTIVE'
		LEFT JOIN contacts viewer_contact ON viewer_contact.owner_user_id=$2::uuid AND viewer_contact.contact_user_id=u.id
		WHERE mc.moment_id=$1 AND mc.deleted_at IS NULL
		  AND ($2::uuid=$3::uuid OR u.id=$2::uuid OR u.id=$3::uuid OR EXISTS(
		    SELECT 1 FROM contacts c WHERE c.owner_user_id=$2::uuid AND c.contact_user_id=u.id
		  ))
		  AND ($2::uuid=$3::uuid OR NOT EXISTS(
		    SELECT 1 FROM blocks b
		    WHERE (b.owner_user_id=$2::uuid AND b.blocked_user_id=u.id)
		       OR (b.owner_user_id=u.id AND b.blocked_user_id=$2::uuid)
		  ))
		ORDER BY mc.created_at,mc.id
	`, momentID, principal.UserID, authorID)
	if err != nil {
		return Moment{}, fmt.Errorf("list moment comments: %w", err)
	}
	for commentRows.Next() {
		var item Comment
		if err := commentRows.Scan(
			&item.ID,
			&item.Author.ID,
			&item.Author.Handle,
			&item.Author.DisplayName,
			&item.ReplyToCommentID,
			&item.Text,
			&item.CreatedAt,
		); err != nil {
			commentRows.Close()
			return Moment{}, fmt.Errorf("scan moment comment: %w", err)
		}
		item.CreatedAt = item.CreatedAt.UTC()
		result.Comments = append(result.Comments, item)
	}
	commentRows.Close()
	if err := commentRows.Err(); err != nil {
		return Moment{}, fmt.Errorf("iterate moment comments: %w", err)
	}
	if result.MediaIDs == nil {
		result.MediaIDs = []string{}
	}
	if result.LikeUsers == nil {
		result.LikeUsers = []UserPreview{}
	}
	if result.Comments == nil {
		result.Comments = []Comment{}
	}
	return result, nil
}

func (service *Service) Delete(ctx context.Context, principal account.Principal, momentID uuid.UUID) ([]uuid.UUID, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return nil, fmt.Errorf("begin delete moment: %w", err)
	}
	defer tx.Rollback(ctx)
	var authorID uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT author_user_id FROM moments WHERE id=$1 AND status='ACTIVE' FOR UPDATE`, momentID).Scan(&authorID); errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, fmt.Errorf("lock moment delete: %w", err)
	}
	if authorID != principal.UserID {
		return nil, ErrForbidden
	}
	recipients, err := audienceUserIDsTx(ctx, tx, momentID, authorID)
	if err != nil {
		return nil, err
	}
	recipients = appendUniqueUUID(recipients, authorID)
	if _, err := tx.Exec(ctx, `UPDATE moments SET status='DELETED',deleted_at=$2 WHERE id=$1`, momentID, now); err != nil {
		return nil, fmt.Errorf("delete moment: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM moment_activity_notifications WHERE moment_id=$1`, momentID); err != nil {
		return nil, fmt.Errorf("delete moment activity: %w", err)
	}
	if err := insertMomentOutboxTx(ctx, tx, momentID, "MOMENT_DELETED", recipients, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit delete moment: %w", err)
	}
	return recipients, nil
}

func (service *Service) SetLike(ctx context.Context, principal account.Principal, momentID uuid.UUID, liked bool) (Moment, []uuid.UUID, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Moment{}, nil, fmt.Errorf("begin moment like: %w", err)
	}
	defer tx.Rollback(ctx)
	authorID, err := authorizeMomentTx(ctx, tx, momentID, principal.UserID)
	if err != nil {
		return Moment{}, nil, err
	}
	if liked {
		if _, err := tx.Exec(ctx, `
			INSERT INTO moment_likes(moment_id,user_id,created_at) VALUES($1,$2,$3)
			ON CONFLICT(moment_id,user_id) DO NOTHING
		`, momentID, principal.UserID, now); err != nil {
			return Moment{}, nil, fmt.Errorf("like moment: %w", err)
		}
		if authorID != principal.UserID {
			if err := insertMomentActivityTx(ctx, tx, authorID, momentID, principal.UserID, "LIKE", nil, now); err != nil {
				return Moment{}, nil, err
			}
		}
	} else {
		if _, err := tx.Exec(ctx, `DELETE FROM moment_likes WHERE moment_id=$1 AND user_id=$2`, momentID, principal.UserID); err != nil {
			return Moment{}, nil, fmt.Errorf("unlike moment: %w", err)
		}
		if authorID != principal.UserID {
			if _, err := tx.Exec(ctx, `
				DELETE FROM moment_activity_notifications
				WHERE recipient_user_id=$1 AND moment_id=$2 AND actor_user_id=$3 AND kind='LIKE'
			`, authorID, momentID, principal.UserID); err != nil {
				return Moment{}, nil, fmt.Errorf("remove moment like activity: %w", err)
			}
		}
	}
	recipients, err := audienceUserIDsTx(ctx, tx, momentID, authorID)
	if err != nil {
		return Moment{}, nil, err
	}
	recipients = appendUniqueUUID(recipients, authorID)
	recipients = appendUniqueUUID(recipients, principal.UserID)
	if err := insertMomentOutboxTx(ctx, tx, momentID, "MOMENT_LIKE_CHANGED", recipients, now); err != nil {
		return Moment{}, nil, err
	}
	if liked && authorID != principal.UserID {
		payload, _ := json.Marshal(map[string]any{
			"momentId":    momentID.String(),
			"actorUserId": principal.UserID.String(),
		})
		if _, err := tx.Exec(ctx, `
			INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
			VALUES($1,'MOMENT_LIKE_CHANGED',$2,$3,$4,$5::jsonb,'PENDING',$6,$6)
			ON CONFLICT(dedupe_key) DO NOTHING
		`, authorID, momentID, principal.UserID, "moment-like:"+momentID.String()+":"+principal.UserID.String(), string(payload), now); err != nil {
			return Moment{}, nil, fmt.Errorf("enqueue moment like push: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Moment{}, nil, fmt.Errorf("commit moment like: %w", err)
	}
	moment, err := service.Get(ctx, principal, momentID)
	return moment, recipients, err
}

func (service *Service) AddComment(ctx context.Context, principal account.Principal, momentID uuid.UUID, raw CommentInput) (Moment, []uuid.UUID, error) {
	text := strings.TrimSpace(raw.Text)
	if text == "" || utf8.RuneCountInString(text) > maximumCommentText {
		return Moment{}, nil, ErrInvalidInput
	}
	var replyID *uuid.UUID
	if raw.ReplyToCommentID != nil && strings.TrimSpace(*raw.ReplyToCommentID) != "" {
		parsed, err := uuid.Parse(strings.TrimSpace(*raw.ReplyToCommentID))
		if err != nil {
			return Moment{}, nil, ErrInvalidInput
		}
		replyID = &parsed
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Moment{}, nil, fmt.Errorf("begin moment comment: %w", err)
	}
	defer tx.Rollback(ctx)
	authorID, err := authorizeMomentTx(ctx, tx, momentID, principal.UserID)
	if err != nil {
		return Moment{}, nil, err
	}
	if replyID != nil {
		var exists bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS(SELECT 1 FROM moment_comments WHERE id=$1 AND moment_id=$2 AND deleted_at IS NULL)
		`, *replyID, momentID).Scan(&exists); err != nil {
			return Moment{}, nil, fmt.Errorf("validate reply comment: %w", err)
		}
		if !exists {
			return Moment{}, nil, ErrNotFound
		}
	}
	commentID := uuid.New()
	if _, err := tx.Exec(ctx, `
		INSERT INTO moment_comments(id,moment_id,author_user_id,reply_to_comment_id,text,created_at)
		VALUES($1,$2,$3,$4,$5,$6)
	`, commentID, momentID, principal.UserID, replyID, text, now); err != nil {
		return Moment{}, nil, fmt.Errorf("insert moment comment: %w", err)
	}
	recipients, err := audienceUserIDsTx(ctx, tx, momentID, authorID)
	if err != nil {
		return Moment{}, nil, err
	}
	recipients = appendUniqueUUID(recipients, authorID)
	recipients = appendUniqueUUID(recipients, principal.UserID)
	if err := insertMomentOutboxTx(ctx, tx, momentID, "MOMENT_COMMENT_CREATED", recipients, now); err != nil {
		return Moment{}, nil, err
	}
	pushRecipients := []uuid.UUID{authorID}
	if replyID != nil {
		var replyAuthorID uuid.UUID
		if err := tx.QueryRow(ctx, `SELECT author_user_id FROM moment_comments WHERE id=$1`, *replyID).Scan(&replyAuthorID); err == nil {
			pushRecipients = appendUniqueUUID(pushRecipients, replyAuthorID)
		}
	}
	for _, recipientID := range pushRecipients {
		if recipientID == principal.UserID {
			continue
		}
		if err := insertMomentActivityTx(ctx, tx, recipientID, momentID, principal.UserID, "COMMENT", &commentID, now); err != nil {
			return Moment{}, nil, err
		}
	}
	payload, _ := json.Marshal(map[string]any{
		"momentId":    momentID.String(),
		"commentId":   commentID.String(),
		"actorUserId": principal.UserID.String(),
	})
	for _, recipientID := range pushRecipients {
		if recipientID == principal.UserID {
			continue
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
			VALUES($1,'MOMENT_COMMENT_CREATED',$2,$3,$4,$5::jsonb,'PENDING',$6,$6)
			ON CONFLICT(dedupe_key) DO NOTHING
		`, recipientID, momentID, principal.UserID, "moment-comment:"+commentID.String()+":user:"+recipientID.String(), string(payload), now); err != nil {
			return Moment{}, nil, fmt.Errorf("enqueue moment comment push: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Moment{}, nil, fmt.Errorf("commit moment comment: %w", err)
	}
	moment, err := service.Get(ctx, principal, momentID)
	return moment, recipients, err
}

func (service *Service) DeleteComment(ctx context.Context, principal account.Principal, momentID, commentID uuid.UUID) (Moment, []uuid.UUID, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Moment{}, nil, fmt.Errorf("begin delete moment comment: %w", err)
	}
	defer tx.Rollback(ctx)
	authorID, err := authorizeMomentTx(ctx, tx, momentID, principal.UserID)
	if err != nil {
		return Moment{}, nil, err
	}
	var commentAuthorID uuid.UUID
	if err := tx.QueryRow(ctx, `
		SELECT author_user_id FROM moment_comments
		WHERE id=$1 AND moment_id=$2 AND deleted_at IS NULL FOR UPDATE
	`, commentID, momentID).Scan(&commentAuthorID); errors.Is(err, pgx.ErrNoRows) {
		return Moment{}, nil, ErrNotFound
	} else if err != nil {
		return Moment{}, nil, fmt.Errorf("lock moment comment: %w", err)
	}
	if commentAuthorID != principal.UserID && authorID != principal.UserID {
		return Moment{}, nil, ErrForbidden
	}
	if _, err := tx.Exec(ctx, `UPDATE moment_comments SET deleted_at=$2 WHERE id=$1`, commentID, now); err != nil {
		return Moment{}, nil, fmt.Errorf("delete moment comment: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM moment_activity_notifications WHERE source_comment_id=$1`, commentID); err != nil {
		return Moment{}, nil, fmt.Errorf("delete moment comment activity: %w", err)
	}
	recipients, err := audienceUserIDsTx(ctx, tx, momentID, authorID)
	if err != nil {
		return Moment{}, nil, err
	}
	recipients = appendUniqueUUID(recipients, authorID)
	recipients = appendUniqueUUID(recipients, principal.UserID)
	if err := insertMomentOutboxTx(ctx, tx, momentID, "MOMENT_COMMENT_DELETED", recipients, now); err != nil {
		return Moment{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Moment{}, nil, fmt.Errorf("commit delete moment comment: %w", err)
	}
	moment, err := service.Get(ctx, principal, momentID)
	return moment, recipients, err
}

func (service *Service) SetPreference(ctx context.Context, principal account.Principal, targetID uuid.UUID, input PreferenceInput) (Preference, error) {
	if targetID == uuid.Nil || targetID == principal.UserID {
		return Preference{}, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return Preference{}, fmt.Errorf("begin moment preference: %w", err)
	}
	defer tx.Rollback(ctx)
	var target UserPreview
	if err := tx.QueryRow(ctx, `
		SELECT u.id::text,u.handle_normalized,COALESCE(NULLIF(c.remark,''),u.display_name)
		FROM users u
		JOIN contacts c ON c.owner_user_id=$1 AND c.contact_user_id=u.id
		WHERE u.id=$2 AND u.status='ACTIVE'
	`, principal.UserID, targetID).Scan(&target.ID, &target.Handle, &target.DisplayName); errors.Is(err, pgx.ErrNoRows) {
		return Preference{}, ErrNotFound
	} else if err != nil {
		return Preference{}, fmt.Errorf("load moment preference target: %w", err)
	}
	if !input.HideTarget && !input.HideFromTarget {
		if _, err := tx.Exec(ctx, `DELETE FROM moment_relationship_preferences WHERE owner_user_id=$1 AND target_user_id=$2`, principal.UserID, targetID); err != nil {
			return Preference{}, fmt.Errorf("clear moment preference: %w", err)
		}
	} else if _, err := tx.Exec(ctx, `
		INSERT INTO moment_relationship_preferences(owner_user_id,target_user_id,hide_target,hide_from_target,updated_at)
		VALUES($1,$2,$3,$4,$5)
		ON CONFLICT(owner_user_id,target_user_id) DO UPDATE SET
		  hide_target=EXCLUDED.hide_target,
		  hide_from_target=EXCLUDED.hide_from_target,
		  updated_at=EXCLUDED.updated_at
	`, principal.UserID, targetID, input.HideTarget, input.HideFromTarget, now); err != nil {
		return Preference{}, fmt.Errorf("save moment preference: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Preference{}, fmt.Errorf("commit moment preference: %w", err)
	}
	return Preference{Target: target, HideTarget: input.HideTarget, HideFromTarget: input.HideFromTarget, UpdatedAt: now}, nil
}

func (service *Service) ListPreferences(ctx context.Context, principal account.Principal) ([]Preference, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT u.id::text,u.handle_normalized,COALESCE(NULLIF(viewer_contact.remark,''),u.display_name),p.hide_target,p.hide_from_target,p.updated_at
		FROM moment_relationship_preferences p
		JOIN users u ON u.id=p.target_user_id AND u.status='ACTIVE'
		LEFT JOIN contacts viewer_contact ON viewer_contact.owner_user_id=$1 AND viewer_contact.contact_user_id=u.id
		WHERE p.owner_user_id=$1
		ORDER BY lower(COALESCE(NULLIF(viewer_contact.remark,''),u.display_name)),u.id
	`, principal.UserID)
	if err != nil {
		return nil, fmt.Errorf("list moment preferences: %w", err)
	}
	defer rows.Close()
	items := make([]Preference, 0)
	for rows.Next() {
		var item Preference
		if err := rows.Scan(&item.Target.ID, &item.Target.Handle, &item.Target.DisplayName, &item.HideTarget, &item.HideFromTarget, &item.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan moment preference: %w", err)
		}
		item.UpdatedAt = item.UpdatedAt.UTC()
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate moment preferences: %w", err)
	}
	return items, nil
}

func (service *Service) GetProfile(ctx context.Context, principal account.Principal, targetID uuid.UUID) (Profile, error) {
	if targetID == uuid.Nil {
		return Profile{}, ErrInvalidInput
	}
	var profile Profile
	var canView bool
	err := service.pool.QueryRow(ctx, `
		SELECT u.id::text,u.handle_normalized,COALESCE(NULLIF(viewer_contact.remark,''),u.display_name),
		       COALESCE(u.moment_cover_media_id::text,''),u.moment_cover_revision,
		       (u.id=$1 OR (
		         EXISTS(SELECT 1 FROM contacts c WHERE c.owner_user_id=$1 AND c.contact_user_id=u.id)
		         AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.owner_user_id=$1 AND b.blocked_user_id=u.id) OR (b.owner_user_id=u.id AND b.blocked_user_id=$1))
		         AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=$1 AND p.target_user_id=u.id AND p.hide_target=true)
		         AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=u.id AND p.target_user_id=$1 AND p.hide_from_target=true)
		       ))
		FROM users u
		LEFT JOIN contacts viewer_contact ON viewer_contact.owner_user_id=$1 AND viewer_contact.contact_user_id=u.id
		WHERE u.id=$2 AND u.status='ACTIVE'
	`, principal.UserID, targetID).Scan(
		&profile.User.ID,
		&profile.User.Handle,
		&profile.User.DisplayName,
		&profile.CoverMediaID,
		&profile.CoverRevision,
		&canView,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, ErrNotFound
	}
	if err != nil {
		return Profile{}, fmt.Errorf("load moment profile: %w", err)
	}
	if !canView {
		return Profile{}, ErrNotFound
	}
	profile.CanEdit = targetID == principal.UserID
	return profile, nil
}

func (service *Service) UpdateProfile(ctx context.Context, principal account.Principal, input UpdateProfileInput) (Profile, []uuid.UUID, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Profile{}, nil, fmt.Errorf("begin moment profile update: %w", err)
	}
	defer tx.Rollback(ctx)

	var coverMediaID *uuid.UUID
	value := strings.TrimSpace(input.CoverMediaID)
	if value != "" {
		parsed, parseErr := uuid.Parse(value)
		if parseErr != nil {
			return Profile{}, nil, ErrInvalidInput
		}
		var ready bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS(
				SELECT 1 FROM media_objects
				WHERE id=$1 AND owner_user_id=$2 AND purpose='MOMENT_COVER'
				  AND status='READY' AND deleted_at IS NULL
			)
		`, parsed, principal.UserID).Scan(&ready); err != nil {
			return Profile{}, nil, fmt.Errorf("verify moment cover media: %w", err)
		}
		if !ready {
			return Profile{}, nil, ErrInvalidInput
		}
		coverMediaID = &parsed
	}
	if _, err := tx.Exec(ctx, `
		UPDATE users
		SET moment_cover_media_id=$2,moment_cover_revision=moment_cover_revision+1,updated_at=$3
		WHERE id=$1 AND status='ACTIVE'
	`, principal.UserID, coverMediaID, now); err != nil {
		return Profile{}, nil, fmt.Errorf("update moment cover: %w", err)
	}
	rows, err := tx.Query(ctx, `
		SELECT c.owner_user_id
		FROM contacts c
		WHERE c.contact_user_id=$1
		  AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.owner_user_id=c.owner_user_id AND b.blocked_user_id=$1) OR (b.owner_user_id=$1 AND b.blocked_user_id=c.owner_user_id))
		  AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=c.owner_user_id AND p.target_user_id=$1 AND p.hide_target=true)
		  AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=$1 AND p.target_user_id=c.owner_user_id AND p.hide_from_target=true)
	`, principal.UserID)
	if err != nil {
		return Profile{}, nil, fmt.Errorf("list moment profile recipients: %w", err)
	}
	recipients := []uuid.UUID{principal.UserID}
	for rows.Next() {
		var userID uuid.UUID
		if err := rows.Scan(&userID); err != nil {
			rows.Close()
			return Profile{}, nil, fmt.Errorf("scan moment profile recipient: %w", err)
		}
		recipients = appendUniqueUUID(recipients, userID)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return Profile{}, nil, fmt.Errorf("iterate moment profile recipients: %w", err)
	}
	if err := insertMomentOutboxTx(ctx, tx, principal.UserID, "MOMENT_PROFILE_UPDATED", recipients, now); err != nil {
		return Profile{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Profile{}, nil, fmt.Errorf("commit moment profile update: %w", err)
	}
	profile, err := service.GetProfile(ctx, principal, principal.UserID)
	return profile, recipients, err
}

func normalizeCreateInput(raw CreateInput) (CreateInput, []uuid.UUID, []uuid.UUID, error) {
	input := raw
	input.Text = strings.TrimSpace(input.Text)
	if utf8.RuneCountInString(input.Text) > maximumMomentText || len(input.MediaIDs) > maximumMomentMedia || len(input.VisibilityUserIDs) > maximumVisibilityUsers {
		return CreateInput{}, nil, nil, ErrInvalidInput
	}
	input.Visibility = strings.ToUpper(strings.TrimSpace(input.Visibility))
	if input.Visibility == "" {
		input.Visibility = VisibilityAllContacts
	}
	if input.Visibility != VisibilityAllContacts && input.Visibility != VisibilityPrivate && input.Visibility != VisibilityExclude {
		return CreateInput{}, nil, nil, ErrInvalidInput
	}
	mediaIDs, err := parseUniqueUUIDs(input.MediaIDs)
	if err != nil {
		return CreateInput{}, nil, nil, err
	}
	visibilityIDs, err := parseUniqueUUIDs(input.VisibilityUserIDs)
	if err != nil {
		return CreateInput{}, nil, nil, err
	}
	if input.Text == "" && len(mediaIDs) == 0 {
		return CreateInput{}, nil, nil, ErrInvalidInput
	}
	if input.Visibility == VisibilityAllContacts && len(visibilityIDs) > 0 {
		return CreateInput{}, nil, nil, ErrInvalidInput
	}
	if input.Visibility == VisibilityPrivate && len(visibilityIDs) == 0 {
		return CreateInput{}, nil, nil, ErrInvalidInput
	}
	return input, mediaIDs, visibilityIDs, nil
}

func parseUniqueUUIDs(raw []string) ([]uuid.UUID, error) {
	items := make([]uuid.UUID, 0, len(raw))
	seen := map[uuid.UUID]struct{}{}
	for _, value := range raw {
		parsed, err := uuid.Parse(strings.TrimSpace(value))
		if err != nil || parsed == uuid.Nil {
			return nil, ErrInvalidInput
		}
		if _, exists := seen[parsed]; exists {
			return nil, ErrInvalidInput
		}
		seen[parsed] = struct{}{}
		items = append(items, parsed)
	}
	return items, nil
}

func validateMomentMediaTx(ctx context.Context, tx pgx.Tx, ownerID uuid.UUID, mediaIDs []uuid.UUID) error {
	if len(mediaIDs) == 0 {
		return nil
	}
	var count int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM media_objects
		WHERE id=ANY($1::uuid[]) AND owner_user_id=$2 AND status='READY'
		  AND purpose IN ('MOMENT_IMAGE','MOMENT_VIDEO')
	`, mediaIDs, ownerID).Scan(&count); err != nil {
		return fmt.Errorf("validate moment media: %w", err)
	}
	if count != len(mediaIDs) {
		return ErrForbidden
	}
	return nil
}

func validateVisibilityTargetsTx(ctx context.Context, tx pgx.Tx, ownerID uuid.UUID, targets []uuid.UUID) error {
	if len(targets) == 0 {
		return nil
	}
	var count int
	if err := tx.QueryRow(ctx, `
		SELECT count(*)
		FROM users u
		JOIN contacts c ON c.owner_user_id=$1 AND c.contact_user_id=u.id
		WHERE u.id=ANY($2::uuid[]) AND u.status='ACTIVE'
		  AND NOT EXISTS(
		    SELECT 1 FROM blocks b
		    WHERE (b.owner_user_id=$1 AND b.blocked_user_id=u.id)
		       OR (b.owner_user_id=u.id AND b.blocked_user_id=$1)
		  )
	`, ownerID, targets).Scan(&count); err != nil {
		return fmt.Errorf("validate moment visibility targets: %w", err)
	}
	if count != len(targets) {
		return ErrForbidden
	}
	return nil
}

func authorizeMomentTx(ctx context.Context, tx pgx.Tx, momentID, viewerID uuid.UUID) (uuid.UUID, error) {
	var authorID uuid.UUID
	if err := tx.QueryRow(ctx, `
		SELECT m.author_user_id FROM moments m
		WHERE m.id=$1 AND m.status='ACTIVE' AND `+momentVisibilitySQL("m", "$2")+`
	`, momentID, viewerID).Scan(&authorID); errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, ErrNotFound
	} else if err != nil {
		return uuid.Nil, fmt.Errorf("authorize moment: %w", err)
	}
	return authorID, nil
}

func momentVisibilitySQL(alias, viewerExpression string) string {
	return fmt.Sprintf(`(
		%s.author_user_id=%s
		OR (
		  EXISTS(SELECT 1 FROM contacts c WHERE c.owner_user_id=%s AND c.contact_user_id=%s.author_user_id)
		  AND NOT EXISTS(
		    SELECT 1 FROM blocks b
		    WHERE (b.owner_user_id=%s AND b.blocked_user_id=%s.author_user_id)
		       OR (b.owner_user_id=%s.author_user_id AND b.blocked_user_id=%s)
		  )
		  AND NOT EXISTS(
		    SELECT 1 FROM moment_relationship_preferences p
		    WHERE p.owner_user_id=%s AND p.target_user_id=%s.author_user_id AND p.hide_target=true
		  )
		  AND NOT EXISTS(
		    SELECT 1 FROM moment_relationship_preferences p
		    WHERE p.owner_user_id=%s.author_user_id AND p.target_user_id=%s AND p.hide_from_target=true
		  )
		  AND (
		    %s.visibility='ALL_CONTACTS'
		    OR (%s.visibility='PRIVATE' AND EXISTS(
		      SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=%s.id AND v.user_id=%s AND v.mode='INCLUDED'
		    ))
		    OR (%s.visibility='EXCLUDE' AND NOT EXISTS(
		      SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=%s.id AND v.user_id=%s AND v.mode='EXCLUDED'
		    ))
		  )
		)
	)`, alias, viewerExpression, viewerExpression, alias, viewerExpression, alias, alias, viewerExpression, viewerExpression, alias, alias, viewerExpression, alias, alias, alias, viewerExpression, alias, alias, viewerExpression)
}

func audienceUserIDsTx(ctx context.Context, tx pgx.Tx, momentID, authorID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := tx.Query(ctx, `
		SELECT c.contact_user_id
		FROM contacts c
		JOIN moments m ON m.id=$2 AND m.author_user_id=$1
		JOIN users viewer ON viewer.id=c.contact_user_id AND viewer.status='ACTIVE'
		WHERE c.owner_user_id=$1
		  AND NOT EXISTS(
		    SELECT 1 FROM blocks b
		    WHERE (b.owner_user_id=$1 AND b.blocked_user_id=c.contact_user_id)
		       OR (b.owner_user_id=c.contact_user_id AND b.blocked_user_id=$1)
		  )
		  AND NOT EXISTS(
		    SELECT 1 FROM moment_relationship_preferences p
		    WHERE p.owner_user_id=c.contact_user_id AND p.target_user_id=$1 AND p.hide_target=true
		  )
		  AND NOT EXISTS(
		    SELECT 1 FROM moment_relationship_preferences p
		    WHERE p.owner_user_id=$1 AND p.target_user_id=c.contact_user_id AND p.hide_from_target=true
		  )
		  AND (
		    m.visibility='ALL_CONTACTS'
		    OR (m.visibility='PRIVATE' AND EXISTS(
		      SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=m.id AND v.user_id=c.contact_user_id AND v.mode='INCLUDED'
		    ))
		    OR (m.visibility='EXCLUDE' AND NOT EXISTS(
		      SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=m.id AND v.user_id=c.contact_user_id AND v.mode='EXCLUDED'
		    ))
		  )
		ORDER BY c.contact_user_id
	`, authorID, momentID)
	if err != nil {
		return nil, fmt.Errorf("list moment audience: %w", err)
	}
	defer rows.Close()
	items := make([]uuid.UUID, 0)
	for rows.Next() {
		var userID uuid.UUID
		if err := rows.Scan(&userID); err != nil {
			return nil, fmt.Errorf("scan moment audience: %w", err)
		}
		items = append(items, userID)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate moment audience: %w", err)
	}
	return items, nil
}

func insertMomentActivityTx(
	ctx context.Context,
	tx pgx.Tx,
	recipientID, momentID, actorID uuid.UUID,
	kind string,
	commentID *uuid.UUID,
	now time.Time,
) error {
	if recipientID == uuid.Nil || momentID == uuid.Nil || actorID == uuid.Nil || recipientID == actorID {
		return nil
	}
	dedupeKey := "moment-like:" + momentID.String() + ":actor:" + actorID.String() + ":user:" + recipientID.String()
	var sourceComment any
	if commentID != nil && *commentID != uuid.Nil {
		dedupeKey = "moment-comment:" + commentID.String() + ":user:" + recipientID.String()
		sourceComment = *commentID
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO moment_activity_notifications(
		  recipient_user_id,moment_id,actor_user_id,kind,source_comment_id,dedupe_key,created_at
		) VALUES($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT(dedupe_key) DO NOTHING
	`, recipientID, momentID, actorID, kind, sourceComment, dedupeKey, now); err != nil {
		return fmt.Errorf("insert moment activity: %w", err)
	}
	return nil
}

func insertMomentOutboxTx(ctx context.Context, tx pgx.Tx, momentID uuid.UUID, eventType string, recipients []uuid.UUID, now time.Time) error {
	payload, err := json.Marshal(map[string]any{"momentId": momentID.String()})
	if err != nil {
		return fmt.Errorf("marshal moment outbox payload: %w", err)
	}
	seen := map[uuid.UUID]struct{}{}
	for _, userID := range recipients {
		if userID == uuid.Nil {
			continue
		}
		if _, exists := seen[userID]; exists {
			continue
		}
		seen[userID] = struct{}{}
		if _, err := tx.Exec(ctx, `
			INSERT INTO outbox_events(
			  aggregate_type,aggregate_id,event_type,target_user_id,payload_json,created_at,available_at
			) VALUES('MOMENT',$1,$2,$3,$4::jsonb,$5,$5)
		`, momentID, eventType, userID, string(payload), now); err != nil {
			return fmt.Errorf("insert moment outbox: %w", err)
		}
	}
	return nil
}

func appendUniqueUUID(items []uuid.UUID, value uuid.UUID) []uuid.UUID {
	if value == uuid.Nil {
		return items
	}
	for _, item := range items {
		if item == value {
			return items
		}
	}
	return append(items, value)
}
