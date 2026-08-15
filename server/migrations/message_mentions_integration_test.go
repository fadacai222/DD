package migrations_test

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/platform/migration"
	"example.com/selfhosted-im/server/migrations"
	"github.com/google/uuid"
)

func TestMessageMentionsMigrationBackfillWithDuplicateAndMalformedEntities(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MIGRATIONS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_MIGRATIONS_TEST_DATABASE_URL is not set")
	}
	all, err := migration.Load(migrations.Files)
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	connection := openIsolatedMigrationDatabase(t, databaseURL)
	defer connection.Close(context.Background())
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	through33 := migrationsThrough(t, all, 33)
	if applied, err := migration.Up(ctx, connection, through33); err != nil || applied != len(through33) {
		t.Fatalf("apply through 000033 applied=%d err=%v", applied, err)
	}

	now := time.Date(2026, 8, 14, 6, 0, 0, 0, time.UTC)
	senderID, bobID, carolID := uuid.New(), uuid.New(), uuid.New()
	deviceID, conversationID := uuid.New(), uuid.New()
	for _, user := range []struct {
		id     uuid.UUID
		handle string
	}{
		{senderID, "mig_sender"},
		{bobID, "mig_bob"},
		{carolID, "mig_carol"},
	} {
		if _, err := connection.Exec(ctx, `
			INSERT INTO users(id,email_normalized,email_verified_at,handle_normalized,display_name,status,created_at,updated_at)
			VALUES($1,$2,$3,$4,$4,'ACTIVE',$3,$3)
		`, user.id, user.handle+"@example.test", now, user.handle); err != nil {
			t.Fatalf("insert migration user %s: %v", user.handle, err)
		}
	}
	if _, err := connection.Exec(ctx, `
		INSERT INTO devices(id,user_id,name,platform,app_version,created_at,last_seen_at)
		VALUES($1,$2,'migration sender','WINDOWS','test',$3,$3)
	`, deviceID, senderID, now); err != nil {
		t.Fatalf("insert migration device: %v", err)
	}
	if _, err := connection.Exec(ctx, `
		INSERT INTO conversations(id,type,last_sequence,created_at,updated_at)
		VALUES($1,'GROUP',3,$2,$2)
	`, conversationID, now); err != nil {
		t.Fatalf("insert migration conversation: %v", err)
	}
	members := []struct {
		id   uuid.UUID
		role string
	}{
		{senderID, "OWNER"},
		{bobID, "MEMBER"},
		{carolID, "MEMBER"},
	}
	for _, member := range members {
		query := "INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at,last_read_sequence) VALUES($1,$2,$3,$4,$5,0)"
		_, err := connection.Exec(ctx, query, conversationID, member.id, member.role, "ACTIVE", now.Add(-time.Hour))
		if err != nil {
			t.Fatalf("insert migration member: %v", err)
		}
	}
	groupQuery := "INSERT INTO groups(conversation_id,name,created_by_user_id,created_at,updated_at) VALUES($1,$2,$3,$4,$4)"
	if _, err := connection.Exec(ctx, groupQuery, conversationID, "Migration Mentions", senderID, now); err != nil {
		t.Fatalf("insert migration group: %v", err)
	}
	duplicateAll := `{"text":"@all twice","entities":[{"type":"MENTION_ALL"},{"type":"MENTION_ALL"}]}`
	malformedEntities := `{"text":"legacy malformed","entities":{"type":"MENTION_ALL"}}`
	duplicateDirect := fmt.Sprintf(`{"text":"@bob twice","entities":[{"type":"MENTION","userId":"%s"},{"type":"MENTION","userId":"%s"}]}`, bobID, bobID)
	messageQuery := "INSERT INTO messages(conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,created_at) VALUES($1,$2,$3,$4,$5,$6,$7::jsonb,$8)"
	contents := []string{duplicateAll, malformedEntities, duplicateDirect}
	for sequence, content := range contents {
		clientID := fmt.Sprintf("migration-message-%d", sequence+1)
		_, err := connection.Exec(ctx, messageQuery, conversationID, sequence+1, senderID, deviceID, clientID, "TEXT", content, now.Add(time.Duration(sequence)*time.Minute))
		if err != nil {
			t.Fatalf("insert historical message %d: %v", sequence+1, err)
		}
	}
	through34 := migrationsThrough(t, all, 34)
	applied, err := migration.Up(ctx, connection, through34)
	if err != nil || applied != 1 {
		t.Fatalf("apply 000034 with historical entities applied=%d err=%v", applied, err)
	}
	var allRows, malformedRows, directRows int
	countQuery := "SELECT count(*) FROM message_mentions WHERE conversation_id=$1 AND sequence=$2"
	if err := connection.QueryRow(ctx, countQuery, conversationID, 1).Scan(&allRows); err != nil {
		t.Fatal(err)
	}
	if err := connection.QueryRow(ctx, countQuery, conversationID, 2).Scan(&malformedRows); err != nil {
		t.Fatal(err)
	}
	if err := connection.QueryRow(ctx, countQuery, conversationID, 3).Scan(&directRows); err != nil {
		t.Fatal(err)
	}
	if allRows != 2 || malformedRows != 0 || directRows != 1 {
		t.Fatalf("backfill rows all=%d malformed=%d direct=%d want 2/0/1", allRows, malformedRows, directRows)
	}
	var senderRows int
	senderQuery := "SELECT count(*) FROM message_mentions WHERE conversation_id=$1 AND mentioned_user_id=$2"
	if err := connection.QueryRow(ctx, senderQuery, conversationID, senderID).Scan(&senderRows); err != nil {
		t.Fatal(err)
	}
	if senderRows != 0 {
		t.Fatalf("sender received %d historical self mention rows", senderRows)
	}
}
