package groups

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/messaging"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestGroupLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_GROUPS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_GROUPS_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer pool.Close()

	suffix := strings.ToLower(strings.ReplaceAll(uuid.New().String(), "-", ""))[:10]
	alice := insertGroupTestUser(t, ctx, pool, "ga"+suffix, "Group Alice")
	bob := insertGroupTestUser(t, ctx, pool, "gb"+suffix, "Group Bob")
	carol := insertGroupTestUser(t, ctx, pool, "gc"+suffix, "Group Carol")
	dave := insertGroupTestUser(t, ctx, pool, "gd"+suffix, "Group Dave")
	eve := insertGroupTestUser(t, ctx, pool, "ge"+suffix, "Group Eve")
	users := []uuid.UUID{alice, bob, carol, dave, eve}
	for _, pair := range [][2]uuid.UUID{{alice, bob}, {alice, carol}, {alice, dave}, {bob, dave}} {
		insertGroupTestContactPair(t, ctx, pool, pair[0], pair[1])
	}
	principals := map[uuid.UUID]account.Principal{}
	for _, userID := range users {
		principals[userID] = account.Principal{UserID: userID, DeviceID: insertGroupTestDevice(t, ctx, pool, userID)}
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM conversations WHERE id IN (SELECT conversation_id FROM groups WHERE created_by_user_id=ANY($1::uuid[]))`, users)
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, users)
	})

	service, err := NewService(Config{Pool: pool})
	if err != nil {
		t.Fatalf("new groups service: %v", err)
	}
	messagingService, err := messaging.NewService(messaging.Config{Pool: pool})
	if err != nil {
		t.Fatalf("new messaging service: %v", err)
	}

	created, err := service.Create(ctx, principals[alice], CreateGroupInput{
		Name:      "核心测试群",
		MemberIDs: []string{bob.String(), carol.String()},
	})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}
	groupID := uuid.MustParse(created.ID)
	if created.MyRole != "OWNER" || created.MemberCount != 3 || created.Name != "核心测试群" {
		t.Fatalf("unexpected created group: %+v", created)
	}
	assertGroupConversationState(t, ctx, pool, groupID, "GROUP", 3)
	if _, err := pool.Exec(ctx, `UPDATE contacts SET remark='Boss' WHERE owner_user_id=$1 AND contact_user_id=$2`, alice, bob); err != nil {
		t.Fatalf("set alice private group-member remark: %v", err)
	}
	aliceMembers, err := service.ListMembers(ctx, principals[alice], groupID)
	if err != nil {
		t.Fatalf("alice list members: %v", err)
	}
	if member := groupMemberByID(aliceMembers, bob); member == nil || member.User.DisplayName != "Boss" {
		t.Fatalf("alice group member preview must use private remark: %#v", member)
	}
	carolMembers, err := service.ListMembers(ctx, principals[carol], groupID)
	if err != nil {
		t.Fatalf("carol list members: %v", err)
	}
	if member := groupMemberByID(carolMembers, bob); member == nil || member.User.DisplayName != "Group Bob" {
		t.Fatalf("carol must not see alice private remark: %#v", member)
	}

	if _, err := service.Get(ctx, principals[eve], groupID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member get err=%v want ErrNotFound", err)
	}
	members, err := service.ListMembers(ctx, principals[bob], groupID)
	if err != nil || len(members) != 3 {
		t.Fatalf("member list count=%d err=%v", len(members), err)
	}

	adminRole := "ADMIN"
	bobMember, err := service.UpdateMember(ctx, principals[alice], groupID, bob, UpdateMemberInput{Role: &adminRole})
	if err != nil || bobMember.Role != "ADMIN" {
		t.Fatalf("promote bob member=%+v err=%v", bobMember, err)
	}
	nickname := "Bobby"
	bobMember, err = service.UpdateMember(ctx, principals[bob], groupID, bob, UpdateMemberInput{Nickname: &nickname})
	if err != nil || bobMember.Nickname != nickname {
		t.Fatalf("set nickname member=%+v err=%v", bobMember, err)
	}
	aliceMembers, err = service.ListMembers(ctx, principals[alice], groupID)
	if err != nil {
		t.Fatalf("alice list members after nickname: %v", err)
	}
	if member := groupMemberByID(aliceMembers, bob); member == nil || member.Nickname != "Bobby" || member.User.DisplayName != "Boss" {
		t.Fatalf("group nickname and viewer remark must remain distinct: %#v", member)
	}
	otherNickname := "forced"
	if _, err := service.UpdateMember(ctx, principals[bob], groupID, carol, UpdateMemberInput{Nickname: &otherNickname}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("admin changing another nickname err=%v want forbidden", err)
	}

	adminMessage, err := messagingService.SendMessage(ctx, principals[bob], groupID, messaging.SendMessageInput{
		ClientMessageID: "group-admin-0001",
		Type:            "TEXT",
		Content:         &messaging.TextContent{Text: "@all 管理员通知"},
	})
	if err != nil {
		t.Fatalf("admin mention-all send: %v", err)
	}
	if !hasEntityType(adminMessage.Message.Content, "MENTION_ALL") {
		t.Fatalf("admin @all must bind MENTION_ALL: %+v", adminMessage.Message.Content)
	}
	aliceGroupConversation, err := messagingService.GetConversation(ctx, principals[alice], groupID)
	if err != nil || aliceGroupConversation.LastMessageSender == nil || aliceGroupConversation.LastMessageSender.DisplayName != "Bobby" {
		t.Fatalf("group sender priority must be nickname > remark > public sender=%#v err=%v", aliceGroupConversation.LastMessageSender, err)
	}
	if aliceGroupConversation.Group == nil {
		t.Fatal("alice group conversation missing group preview")
	}
	if member := messagingPreviewByID(aliceGroupConversation.Group.AvatarMembers, bob); member == nil || member.DisplayName != "Bobby" {
		t.Fatalf("group avatar member priority must be nickname > remark > public: %#v", member)
	}
	memberMessage, err := messagingService.SendMessage(ctx, principals[carol], groupID, messaging.SendMessageInput{
		ClientMessageID: "group-member-0001",
		Type:            "TEXT",
		Content:         &messaging.TextContent{Text: "@all 普通成员文本"},
	})
	if err != nil {
		t.Fatalf("member mention-all send: %v", err)
	}
	if hasEntityType(memberMessage.Message.Content, "MENTION_ALL") {
		t.Fatalf("member @all must remain ordinary text: %+v", memberMessage.Message.Content)
	}
	outsiderMention, err := messagingService.SendMessage(ctx, principals[bob], groupID, messaging.SendMessageInput{
		ClientMessageID: "group-admin-0002",
		Type:            "TEXT",
		Content:         &messaging.TextContent{Text: "@" + groupTestHandle(t, ctx, pool, eve) + " outsider"},
	})
	if err != nil {
		t.Fatalf("outsider mention send: %v", err)
	}
	if len(outsiderMention.Message.Content.Entities) != 0 {
		t.Fatalf("GROUP mention must not bind outsider: %+v", outsiderMention.Message.Content.Entities)
	}

	if err := service.RemoveMember(ctx, principals[bob], groupID, carol); err != nil {
		t.Fatalf("admin remove member: %v", err)
	}
	if _, err := messagingService.SendMessage(ctx, principals[carol], groupID, messaging.SendMessageInput{
		ClientMessageID: "group-removed-01",
		Type:            "TEXT",
		Content:         &messaging.TextContent{Text: "should fail"},
	}); !errors.Is(err, messaging.ErrNotFound) {
		t.Fatalf("removed member send err=%v want messaging.ErrNotFound", err)
	}
	if _, err := messagingService.ListMessages(ctx, principals[carol], groupID, 0, 20); !errors.Is(err, messaging.ErrNotFound) {
		t.Fatalf("removed member history err=%v want messaging.ErrNotFound", err)
	}

	invited, err := service.InviteMembers(ctx, principals[alice], groupID, InviteMembersInput{UserIDs: []string{dave.String()}})
	if err != nil || len(invited) != 1 || invited[0].User.ID != dave.String() {
		t.Fatalf("invite dave items=%+v err=%v", invited, err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO blocks(owner_user_id,blocked_user_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, alice, dave); err != nil {
		t.Fatalf("insert same-group block: %v", err)
	}
	if _, err := messagingService.SendMessage(ctx, principals[dave], groupID, messaging.SendMessageInput{
		ClientMessageID: "group-blocked-01",
		Type:            "TEXT",
		Content:         &messaging.TextContent{Text: "shared group remains usable"},
	}); err != nil {
		t.Fatalf("same-group block must not silently remove group membership: %v", err)
	}
	if _, err := service.InviteMembers(ctx, principals[alice], groupID, InviteMembersInput{UserIDs: []string{eve.String()}}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-contact invite err=%v want forbidden", err)
	}

	approval := "APPROVAL"
	updated, err := service.Update(ctx, principals[alice], groupID, UpdateGroupInput{JoinMode: &approval})
	if err != nil || updated.JoinMode != approval {
		t.Fatalf("enable approval group=%+v err=%v", updated, err)
	}
	joinRequest, err := service.CreateJoinRequest(ctx, principals[eve], groupID, CreateJoinRequestInput{Message: "申请加入"})
	if err != nil || joinRequest.Status != "PENDING" {
		t.Fatalf("create join request=%+v err=%v", joinRequest, err)
	}
	requests, err := service.ListJoinRequests(ctx, principals[bob], groupID)
	if err != nil || len(requests) != 1 || requests[0].ID != joinRequest.ID {
		t.Fatalf("admin list requests=%+v err=%v", requests, err)
	}
	approved, err := service.ResolveJoinRequest(ctx, principals[bob], groupID, uuid.MustParse(joinRequest.ID), true)
	if err != nil || approved.Status != "APPROVED" {
		t.Fatalf("approve join request=%+v err=%v", approved, err)
	}
	if group, err := service.Get(ctx, principals[eve], groupID); err != nil || group.MemberCount != 4 {
		t.Fatalf("approved member group=%+v err=%v", group, err)
	}

	transferred, err := service.TransferOwnership(ctx, principals[alice], groupID, TransferOwnershipInput{UserID: bob.String()})
	if err != nil || transferred.OwnerUserID != bob.String() || transferred.MyRole != "MEMBER" {
		t.Fatalf("transfer ownership group=%+v err=%v", transferred, err)
	}
	if err := service.Dissolve(ctx, principals[alice], groupID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("old owner dissolve err=%v want forbidden", err)
	}
	if err := service.Dissolve(ctx, principals[bob], groupID); err != nil {
		t.Fatalf("new owner dissolve: %v", err)
	}
	if _, err := service.Get(ctx, principals[bob], groupID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("dissolved group get err=%v want not found", err)
	}

	processed, err := messagingService.DispatchOutbox(ctx, 200)
	if err != nil || processed == 0 {
		t.Fatalf("dispatch group outbox processed=%d err=%v", processed, err)
	}
	var groupSyncEvents int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM sync_events WHERE event_type LIKE 'GROUP_%' AND user_id=ANY($1::uuid[])`, users).Scan(&groupSyncEvents); err != nil {
		t.Fatalf("count group sync events: %v", err)
	}
	if groupSyncEvents == 0 {
		t.Fatal("expected durable GROUP sync events")
	}
}

func messagingPreviewByID(items []messaging.UserPreview, userID uuid.UUID) *messaging.UserPreview {
	for index := range items {
		if items[index].ID == userID.String() {
			return &items[index]
		}
	}
	return nil
}

func groupMemberByID(items []GroupMember, userID uuid.UUID) *GroupMember {
	for index := range items {
		if items[index].User.ID == userID.String() {
			return &items[index]
		}
	}
	return nil
}

func hasEntityType(content *messaging.TextContent, entityType string) bool {
	if content == nil {
		return false
	}
	for _, entity := range content.Entities {
		if entity.Type == entityType {
			return true
		}
	}
	return false
}

func insertGroupTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	email := fmt.Sprintf("%s@example.invalid", handle)
	if _, err := pool.Exec(ctx, `
		INSERT INTO users(id,email_normalized,email_verified_at,handle_normalized,display_name,status,created_at,updated_at)
		VALUES($1,$2,now(),$3,$4,'ACTIVE',now(),now())
	`, id, email, handle, displayName); err != nil {
		t.Fatalf("insert group test user %s: %v", handle, err)
	}
	return id
}

func insertGroupTestDevice(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO devices(id,user_id,name,platform,created_at,last_seen_at)
		VALUES($1,$2,'group-test','WINDOWS',now(),now())
	`, id, userID); err != nil {
		t.Fatalf("insert group test device: %v", err)
	}
	return id
}

func insertGroupTestContactPair(t *testing.T, ctx context.Context, pool *pgxpool.Pool, a, b uuid.UUID) {
	t.Helper()
	if _, err := pool.Exec(ctx, `
		INSERT INTO contacts(owner_user_id,contact_user_id,remark,is_starred,created_at,updated_at)
		VALUES($1,$2,'',false,now(),now()),($2,$1,'',false,now(),now())
		ON CONFLICT(owner_user_id,contact_user_id) DO NOTHING
	`, a, b); err != nil {
		t.Fatalf("insert group test contacts: %v", err)
	}
}

func assertGroupConversationState(t *testing.T, ctx context.Context, pool *pgxpool.Pool, groupID uuid.UUID, wantType string, wantMembers int) {
	t.Helper()
	var conversationType string
	var count int
	if err := pool.QueryRow(ctx, `
		SELECT c.type,(SELECT count(*) FROM conversation_members cm WHERE cm.conversation_id=c.id AND cm.status='ACTIVE')
		FROM conversations c WHERE c.id=$1
	`, groupID).Scan(&conversationType, &count); err != nil {
		t.Fatalf("load group conversation state: %v", err)
	}
	if conversationType != wantType || count != wantMembers {
		t.Fatalf("conversation type=%s members=%d want %s/%d", conversationType, count, wantType, wantMembers)
	}
}

func groupTestHandle(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID) string {
	t.Helper()
	var handle string
	if err := pool.QueryRow(ctx, `SELECT handle_normalized FROM users WHERE id=$1`, userID).Scan(&handle); err != nil {
		t.Fatalf("load group test handle: %v", err)
	}
	return handle
}
