package moments

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/media"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestMomentPrivacyLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MOMENTS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_MOMENTS_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer pool.Close()

	suffix := strings.ToLower(strings.ReplaceAll(uuid.NewString(), "-", ""))[:10]
	alice := insertMomentTestUser(t, ctx, pool, "ma"+suffix, "Moment Alice")
	bob := insertMomentTestUser(t, ctx, pool, "mb"+suffix, "Moment Bob")
	carol := insertMomentTestUser(t, ctx, pool, "mc"+suffix, "Moment Carol")
	dave := insertMomentTestUser(t, ctx, pool, "md"+suffix, "Moment Dave")
	users := []uuid.UUID{alice, bob, carol, dave}
	insertMomentTestContactPair(t, ctx, pool, alice, bob)
	insertMomentTestContactPair(t, ctx, pool, alice, carol)
	if _, err := pool.Exec(ctx, `UPDATE contacts SET remark='Moment Alice Alias' WHERE owner_user_id=$1 AND contact_user_id=$2`, bob, alice); err != nil {
		t.Fatalf("seed bob moment remark: %v", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE contacts SET remark='Moment Bob Alias' WHERE owner_user_id=$1 AND contact_user_id=$2`, alice, bob); err != nil {
		t.Fatalf("seed alice moment remark: %v", err)
	}
	principals := map[uuid.UUID]account.Principal{
		alice: {UserID: alice}, bob: {UserID: bob}, carol: {UserID: carol}, dave: {UserID: dave},
	}
	mediaID := insertMomentTestMedia(t, ctx, pool, alice, "MOMENT_IMAGE")
	chatMediaID := insertMomentTestMedia(t, ctx, pool, alice, "CHAT_IMAGE")
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, users)
	})

	service, err := NewService(Config{Pool: pool, Now: func() time.Time { return time.Date(2026, 8, 10, 15, 0, 0, 0, time.UTC) }})
	if err != nil {
		t.Fatalf("new moments service: %v", err)
	}

	all, recipients, err := service.Create(ctx, principals[alice], CreateInput{
		Text:       "所有好友可见",
		MediaIDs:   []string{mediaID.String()},
		Visibility: VisibilityAllContacts,
	})
	if err != nil {
		t.Fatalf("create all contacts moment: %v", err)
	}
	if len(all.MediaIDs) != 1 || all.MediaIDs[0] != mediaID.String() {
		t.Fatalf("unexpected media ids: %+v", all.MediaIDs)
	}
	assertUUIDSet(t, recipients, alice, bob, carol)
	allID := uuid.MustParse(all.ID)
	bobInitialView, err := service.Get(ctx, principals[bob], allID)
	if err != nil || bobInitialView.Author.DisplayName != "Moment Alice Alias" {
		t.Fatalf("bob viewer-relative moment author=%q err=%v", bobInitialView.Author.DisplayName, err)
	}
	carolInitialView, err := service.Get(ctx, principals[carol], allID)
	if err != nil || carolInitialView.Author.DisplayName != "Moment Alice" {
		t.Fatalf("carol must not see bob private remark author=%q err=%v", carolInitialView.Author.DisplayName, err)
	}
	if _, err := service.Get(ctx, principals[dave], allID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider get err=%v want ErrNotFound", err)
	}

	if _, _, err := service.Create(ctx, principals[alice], CreateInput{
		Text: "wrong media purpose", MediaIDs: []string{chatMediaID.String()}, Visibility: VisibilityAllContacts,
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("CHAT_IMAGE used by moments err=%v want ErrForbidden", err)
	}

	privateMoment, _, err := service.Create(ctx, principals[alice], CreateInput{
		Text: "仅 Bob 可见", Visibility: VisibilityPrivate, VisibilityUserIDs: []string{bob.String()},
	})
	if err != nil {
		t.Fatalf("create private moment: %v", err)
	}
	privateID := uuid.MustParse(privateMoment.ID)
	if _, err := service.Get(ctx, principals[bob], privateID); err != nil {
		t.Fatalf("included bob should see private moment: %v", err)
	}
	if _, err := service.Get(ctx, principals[carol], privateID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-included carol err=%v want ErrNotFound", err)
	}

	excludedMoment, _, err := service.Create(ctx, principals[alice], CreateInput{
		Text: "排除 Carol", Visibility: VisibilityExclude, VisibilityUserIDs: []string{carol.String()},
	})
	if err != nil {
		t.Fatalf("create exclude moment: %v", err)
	}
	excludedID := uuid.MustParse(excludedMoment.ID)
	if _, err := service.Get(ctx, principals[bob], excludedID); err != nil {
		t.Fatalf("bob should see excluded moment: %v", err)
	}
	if _, err := service.Get(ctx, principals[carol], excludedID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("excluded carol err=%v want ErrNotFound", err)
	}

	liked, recipients, err := service.SetLike(ctx, principals[bob], allID, true)
	if err != nil || !liked.LikedByMe {
		t.Fatalf("bob like moment=%+v err=%v", liked, err)
	}
	assertUUIDSet(t, recipients, alice, bob, carol)
	if _, _, err := service.SetLike(ctx, principals[bob], allID, true); err != nil {
		t.Fatalf("duplicate like must be idempotent: %v", err)
	}

	bobCommented, _, err := service.AddComment(ctx, principals[bob], allID, CommentInput{Text: "Bob comment"})
	if err != nil || len(bobCommented.Comments) != 1 {
		t.Fatalf("bob comment moment=%+v err=%v", bobCommented, err)
	}
	bobCommentID := uuid.MustParse(bobCommented.Comments[0].ID)

	carolCommented, _, err := service.AddComment(ctx, principals[carol], allID, CommentInput{
		Text: "Carol reply", ReplyToCommentID: pointerString(bobCommentID.String()),
	})
	if err != nil {
		t.Fatalf("carol reply: %v", err)
	}
	if len(carolCommented.Comments) != 1 || carolCommented.Comments[0].Author.ID != carol.String() {
		t.Fatalf("carol should only see her own non-mutual interaction, got %+v", carolCommented.Comments)
	}
	carolCommentID := uuid.MustParse(carolCommented.Comments[0].ID)
	bobView, err := service.Get(ctx, principals[bob], allID)
	if err != nil {
		t.Fatalf("bob reload moment: %v", err)
	}
	if len(bobView.Comments) != 1 || bobView.Comments[0].Author.ID != bob.String() {
		t.Fatalf("bob must not learn non-contact Carol interaction: %+v", bobView.Comments)
	}
	aliceView, err := service.Get(ctx, principals[alice], allID)
	if err != nil || len(aliceView.Comments) != 2 {
		t.Fatalf("author must see all comments count=%d err=%v", len(aliceView.Comments), err)
	}
	aliceActivity, err := service.GetActivitySummary(ctx, principals[alice])
	if err != nil || aliceActivity.UnreadCount != 3 {
		t.Fatalf("alice unread moment activity=%d err=%v want=3", aliceActivity.UnreadCount, err)
	}
	if len(aliceActivity.Items) != 3 {
		t.Fatalf("alice recent activity count=%d want=3 items=%+v", len(aliceActivity.Items), aliceActivity.Items)
	}
	foundCarolReply := false
	foundBobAlias := false
	for _, item := range aliceActivity.Items {
		if item.Actor.ID == bob.String() && item.Actor.DisplayName == "Moment Bob Alias" {
			foundBobAlias = true
		}
		if item.Kind == "COMMENT" && item.Actor.ID == carol.String() && item.CommentText == "Carol reply" {
			foundCarolReply = true
		}
	}
	if !foundCarolReply || !foundBobAlias {
		t.Fatalf("alice recent activity=%+v missing viewer-relative actor labels", aliceActivity.Items)
	}
	bobActivity, err := service.GetActivitySummary(ctx, principals[bob])
	if err != nil || bobActivity.UnreadCount != 1 {
		t.Fatalf("bob reply activity=%d err=%v want=1", bobActivity.UnreadCount, err)
	}
	if len(bobActivity.Items) != 1 || bobActivity.Items[0].Actor.ID != carol.String() || bobActivity.Items[0].CommentText != "Carol reply" {
		t.Fatalf("bob recent activity=%+v want Carol reply", bobActivity.Items)
	}
	aliceActivity, err = service.MarkActivityRead(ctx, principals[alice])
	if err != nil || aliceActivity.UnreadCount != 0 {
		t.Fatalf("mark alice activity read=%d err=%v want=0", aliceActivity.UnreadCount, err)
	}
	if len(aliceActivity.Items) != 3 {
		t.Fatalf("mark-read must retain recent history items=%+v", aliceActivity.Items)
	}
	for _, item := range aliceActivity.Items {
		if !item.Read {
			t.Fatalf("mark-read item still unread: %+v", item)
		}
	}
	if _, _, err := service.DeleteComment(ctx, principals[bob], allID, carolCommentID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("bob deleting Carol comment err=%v want forbidden", err)
	}
	if _, _, err := service.DeleteComment(ctx, principals[alice], allID, carolCommentID); err != nil {
		t.Fatalf("moment author deleting Carol comment: %v", err)
	}
	bobActivity, err = service.GetActivitySummary(ctx, principals[bob])
	if err != nil || bobActivity.UnreadCount != 0 {
		t.Fatalf("deleted reply must clear bob activity=%d err=%v", bobActivity.UnreadCount, err)
	}
	if _, _, err := service.DeleteComment(ctx, principals[bob], allID, bobCommentID); err != nil {
		t.Fatalf("comment author deleting own comment: %v", err)
	}

	if _, err := service.SetPreference(ctx, principals[bob], alice, PreferenceInput{HideTarget: true}); err != nil {
		t.Fatalf("bob hide alice: %v", err)
	}
	if _, err := service.Get(ctx, principals[bob], allID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("hideTarget should hide alice feed err=%v", err)
	}
	if _, err := service.SetPreference(ctx, principals[bob], alice, PreferenceInput{}); err != nil {
		t.Fatalf("bob clear preference: %v", err)
	}
	if _, err := service.SetPreference(ctx, principals[alice], bob, PreferenceInput{HideFromTarget: true}); err != nil {
		t.Fatalf("alice hide from bob: %v", err)
	}
	if _, err := service.Get(ctx, principals[bob], allID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("hideFromTarget should hide moment err=%v", err)
	}
	if _, err := service.SetPreference(ctx, principals[alice], bob, PreferenceInput{}); err != nil {
		t.Fatalf("alice clear preference: %v", err)
	}

	if _, err := pool.Exec(ctx, `INSERT INTO blocks(owner_user_id,blocked_user_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, alice, bob); err != nil {
		t.Fatalf("block bob: %v", err)
	}
	if _, err := service.Get(ctx, principals[bob], allID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("blocked bob get err=%v want not found", err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM blocks WHERE owner_user_id=$1 AND blocked_user_id=$2`, alice, bob); err != nil {
		t.Fatalf("unblock bob: %v", err)
	}

	store := &momentTestStore{}
	mediaService, err := media.NewService(media.Config{Pool: pool, Store: store})
	if err != nil {
		t.Fatalf("new media service: %v", err)
	}
	if _, err := mediaService.GetMedia(ctx, principals[bob], mediaID); err != nil {
		t.Fatalf("visible friend must access moment media: %v", err)
	}
	if _, err := service.SetPreference(ctx, principals[alice], bob, PreferenceInput{HideFromTarget: true}); err != nil {
		t.Fatalf("hide media from bob: %v", err)
	}
	if _, err := mediaService.GetMedia(ctx, principals[bob], mediaID); !errors.Is(err, media.ErrForbidden) {
		t.Fatalf("hidden friend media err=%v want media.ErrForbidden", err)
	}
	if _, err := service.SetPreference(ctx, principals[alice], bob, PreferenceInput{}); err != nil {
		t.Fatalf("clear media privacy: %v", err)
	}

	feed, err := service.ListFeed(ctx, principals[bob], nil, nil, 20)
	if err != nil || len(feed) < 3 {
		t.Fatalf("bob feed count=%d err=%v", len(feed), err)
	}
	aliceFeed, err := service.ListFeed(ctx, principals[bob], nil, &alice, 20)
	if err != nil || len(aliceFeed) < 3 {
		t.Fatalf("bob filtered alice feed count=%d err=%v", len(aliceFeed), err)
	}
	for _, item := range aliceFeed {
		if item.Author.ID != alice.String() {
			t.Fatalf("filtered feed leaked author=%s want=%s", item.Author.ID, alice)
		}
	}

	if _, err := pool.Exec(ctx, `DELETE FROM contacts WHERE (owner_user_id=$1 AND contact_user_id=$2) OR (owner_user_id=$2 AND contact_user_id=$1)`, alice, bob); err != nil {
		t.Fatalf("delete contacts: %v", err)
	}
	if _, err := service.Get(ctx, principals[bob], allID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed contact old moment err=%v want ErrNotFound", err)
	}
	removedContactFeed, err := service.ListFeed(ctx, principals[bob], nil, &alice, 20)
	if err != nil || len(removedContactFeed) != 0 {
		t.Fatalf("removed contact filtered feed count=%d err=%v want empty", len(removedContactFeed), err)
	}
	if _, _, err := service.SetLike(ctx, principals[bob], allID, false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed contact interaction err=%v want ErrNotFound", err)
	}

	if _, err := service.Delete(ctx, principals[bob], allID); !errors.Is(err, ErrForbidden) && !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-author delete err=%v want forbidden/notfound", err)
	}
	if _, err := service.Delete(ctx, principals[alice], allID); err != nil {
		t.Fatalf("author delete moment: %v", err)
	}
	if _, err := service.Get(ctx, principals[alice], allID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted moment get err=%v want not found", err)
	}

	var authorOutbox int
	if err := pool.QueryRow(ctx, `
		SELECT count(*) FROM outbox_events
		WHERE aggregate_type='MOMENT' AND aggregate_id=$1 AND target_user_id=$2
	`, allID, alice).Scan(&authorOutbox); err != nil || authorOutbox == 0 {
		t.Fatalf("author multi-device moment outbox count=%d err=%v", authorOutbox, err)
	}
}

func insertMomentTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO users(id,email_normalized,email_verified_at,handle_normalized,display_name,status,created_at,updated_at)
		VALUES($1,$2,now(),$3,$4,'ACTIVE',now(),now())
	`, id, fmt.Sprintf("%s@example.invalid", handle), handle, displayName); err != nil {
		t.Fatalf("insert moment test user: %v", err)
	}
	return id
}

func insertMomentTestContactPair(t *testing.T, ctx context.Context, pool *pgxpool.Pool, a, b uuid.UUID) {
	t.Helper()
	if _, err := pool.Exec(ctx, `
		INSERT INTO contacts(owner_user_id,contact_user_id,remark,is_starred,created_at,updated_at)
		VALUES($1,$2,'',false,now(),now()),($2,$1,'',false,now(),now())
		ON CONFLICT(owner_user_id,contact_user_id) DO NOTHING
	`, a, b); err != nil {
		t.Fatalf("insert moment test contact pair: %v", err)
	}
}

func insertMomentTestMedia(t *testing.T, ctx context.Context, pool *pgxpool.Pool, owner uuid.UUID, purpose string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	key := "moment-test/" + id.String()
	if _, err := pool.Exec(ctx, `
		INSERT INTO media_objects(id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at)
		VALUES($1,$2,$3,'photo.jpg','image/jpeg',128,$4,$5,'READY','NONE',now(),now())
	`, id, owner, key, strings.Repeat("a", 64), purpose); err != nil {
		t.Fatalf("insert moment test media purpose=%s: %v", purpose, err)
	}
	return id
}

func assertUUIDSet(t *testing.T, got []uuid.UUID, want ...uuid.UUID) {
	t.Helper()
	gotSet := map[uuid.UUID]struct{}{}
	for _, id := range got {
		gotSet[id] = struct{}{}
	}
	if len(gotSet) != len(want) {
		t.Fatalf("recipient count=%d want=%d got=%v", len(gotSet), len(want), got)
	}
	for _, id := range want {
		if _, ok := gotSet[id]; !ok {
			t.Fatalf("missing recipient %s in %v", id, got)
		}
	}
}

func pointerString(value string) *string { return &value }

type momentTestStore struct{}

func (*momentTestStore) PresignPut(key, contentType, sha256Hex string, ttl time.Duration) (string, map[string]string, time.Time, error) {
	return "https://example.invalid/upload", map[string]string{}, time.Now().Add(ttl), nil
}
func (*momentTestStore) PresignGet(key string, ttl time.Duration) (string, time.Time, error) {
	return "https://example.invalid/download", time.Now().Add(ttl), nil
}
func (*momentTestStore) Stat(ctx context.Context, key string) (media.ObjectInfo, error) {
	return media.ObjectInfo{}, nil
}
func (*momentTestStore) Delete(ctx context.Context, key string) error { return nil }
