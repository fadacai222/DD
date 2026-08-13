package messaging

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestNormalizeSendInput(t *testing.T) {
	tests := []struct {
		name    string
		input   SendMessageInput
		wantErr error
	}{
		{name: "valid text", input: SendMessageInput{ClientMessageID: "client-0001", Type: "text", Content: &TextContent{Text: " hello "}}},
		{name: "missing client id", input: SendMessageInput{Type: "TEXT", Content: &TextContent{Text: "hello"}}, wantErr: ErrInvalidInput},
		{name: "blank text", input: SendMessageInput{ClientMessageID: "client-0002", Type: "TEXT", Content: &TextContent{Text: "   "}}, wantErr: ErrInvalidInput},
		{name: "too long", input: SendMessageInput{ClientMessageID: "client-0003", Type: "TEXT", Content: &TextContent{Text: strings.Repeat("界", MaximumTextRunes+1)}}, wantErr: ErrInvalidInput},
		{name: "valid image", input: SendMessageInput{ClientMessageID: "client-0004", Type: "IMAGE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000123", Width: 1080, Height: 1440}}},
		{name: "valid live photo", input: SendMessageInput{ClientMessageID: "client-live-0001", Type: "IMAGE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000123", LivePhoto: true, LivePhotoMotionMediaID: "00000000-0000-0000-0000-000000000130", Width: 1080, Height: 1440}}},
		{name: "live photo missing motion", input: SendMessageInput{ClientMessageID: "client-live-0002", Type: "IMAGE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000123", LivePhoto: true, Width: 1080, Height: 1440}}, wantErr: ErrInvalidInput},
		{name: "motion without live photo flag", input: SendMessageInput{ClientMessageID: "client-live-0003", Type: "IMAGE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000123", LivePhotoMotionMediaID: "00000000-0000-0000-0000-000000000130", Width: 1080, Height: 1440}}, wantErr: ErrInvalidInput},
		{name: "live photo motion matches still", input: SendMessageInput{ClientMessageID: "client-live-0004", Type: "IMAGE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000123", LivePhoto: true, LivePhotoMotionMediaID: "00000000-0000-0000-0000-000000000123", Width: 1080, Height: 1440}}, wantErr: ErrInvalidInput},
		{name: "image missing media id", input: SendMessageInput{ClientMessageID: "client-0005", Type: "IMAGE", Content: &TextContent{Width: 1080, Height: 1440}}, wantErr: ErrInvalidInput},
		{name: "image invalid dimensions", input: SendMessageInput{ClientMessageID: "client-0006", Type: "IMAGE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000123", Width: 0, Height: 1440}}, wantErr: ErrInvalidInput},
		{name: "valid gif", input: SendMessageInput{ClientMessageID: "client-0007", Type: "GIF", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000124", Width: 480, Height: 320}}},
		{name: "valid sticker", input: SendMessageInput{ClientMessageID: "client-0008", Type: "STICKER", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000125", Width: 512, Height: 512}}},
		{name: "valid sticker pack share", input: SendMessageInput{ClientMessageID: "client-pack-0001", Type: "STICKER_PACK", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000125", Width: 512, Height: 512}}},
		{name: "sticker pack share missing preview", input: SendMessageInput{ClientMessageID: "client-pack-0002", Type: "STICKER_PACK", Content: &TextContent{}}, wantErr: ErrInvalidInput},
		{name: "valid file", input: SendMessageInput{ClientMessageID: "client-0009", Type: "FILE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000126"}}},
		{name: "valid voice", input: SendMessageInput{ClientMessageID: "client-0010", Type: "VOICE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000127", DurationMS: 4200}}},
		{name: "voice too short", input: SendMessageInput{ClientMessageID: "client-0011", Type: "VOICE", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000127", DurationMS: 100}}, wantErr: ErrInvalidInput},
		{name: "valid video", input: SendMessageInput{ClientMessageID: "client-0014", Type: "VIDEO", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000128", PosterMediaID: "00000000-0000-0000-0000-000000000129", Width: 1920, Height: 1080, DurationMS: 42000}}},
		{name: "video missing poster", input: SendMessageInput{ClientMessageID: "client-0015", Type: "VIDEO", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000128", Width: 1920, Height: 1080, DurationMS: 42000}}, wantErr: ErrInvalidInput},
		{name: "video poster matches primary", input: SendMessageInput{ClientMessageID: "client-0016", Type: "VIDEO", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000128", PosterMediaID: "00000000-0000-0000-0000-000000000128", Width: 1920, Height: 1080, DurationMS: 42000}}, wantErr: ErrInvalidInput},
		{name: "video rejects live photo fields", input: SendMessageInput{ClientMessageID: "client-live-0005", Type: "VIDEO", Content: &TextContent{MediaID: "00000000-0000-0000-0000-000000000128", PosterMediaID: "00000000-0000-0000-0000-000000000129", LivePhoto: true, LivePhotoMotionMediaID: "00000000-0000-0000-0000-000000000130", Width: 1920, Height: 1080, DurationMS: 42000}}, wantErr: ErrInvalidInput},
		{name: "unsupported type", input: SendMessageInput{ClientMessageID: "client-0012", Type: "POLL", Content: &TextContent{Text: "x"}}, wantErr: ErrUnsupportedType},
		{name: "bad reply uuid", input: SendMessageInput{ClientMessageID: "client-0013", Type: "TEXT", Content: &TextContent{Text: "x"}, ReplyToMessageID: stringPointer("not-a-uuid")}, wantErr: ErrInvalidInput},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := normalizeSendInput(tt.input)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error=%v want=%v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.Type != strings.ToUpper(tt.input.Type) || got.Content == nil {
				t.Fatalf("normalized=%#v", got)
			}
		})
	}
}

func TestNormalizeEditMessageInput(t *testing.T) {
	tests := []struct {
		name    string
		input   EditMessageInput
		wantErr error
	}{
		{name: "valid", input: EditMessageInput{Text: "updated text", ExpectedEditVersion: 0}},
		{name: "preserve surrounding spaces", input: EditMessageInput{Text: "  updated text  ", ExpectedEditVersion: 2}},
		{name: "blank", input: EditMessageInput{Text: "   ", ExpectedEditVersion: 0}, wantErr: ErrInvalidInput},
		{name: "too long", input: EditMessageInput{Text: strings.Repeat("界", MaximumTextRunes+1), ExpectedEditVersion: 0}, wantErr: ErrInvalidInput},
		{name: "nul", input: EditMessageInput{Text: "hello\x00world", ExpectedEditVersion: 0}, wantErr: ErrInvalidInput},
		{name: "negative version", input: EditMessageInput{Text: "updated", ExpectedEditVersion: -1}, wantErr: ErrInvalidInput},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := normalizeEditMessageInput(tt.input)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error=%v want=%v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.Text != tt.input.Text || got.ExpectedEditVersion != tt.input.ExpectedEditVersion {
				t.Fatalf("normalized=%#v input=%#v", got, tt.input)
			}
		})
	}
}

func TestGroupPreviewJSONAlwaysCarriesAvatarMembers(t *testing.T) {
	payload, err := json.Marshal(GroupPreview{
		ID:          "group-1",
		Name:        "研发群",
		MemberCount: 2,
		AvatarMembers: []UserPreview{
			{ID: "u1", Handle: "alice", DisplayName: "Alice"},
			{ID: "u2", Handle: "bob", DisplayName: "Bob"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	members, ok := decoded["avatarMembers"].([]any)
	if !ok || len(members) != 2 {
		t.Fatalf("avatarMembers=%#v", decoded["avatarMembers"])
	}
}

func TestConversationJSONCarriesDurableMentionTarget(t *testing.T) {
	messageID := "00000000-0000-0000-0000-000000000777"
	sequence := int64(42)
	payload, err := json.Marshal(Conversation{
		ID:                             "group-1",
		Type:                           "GROUP",
		LatestUnreadMentionMessageID:   &messageID,
		LatestUnreadMentionSequence:    &sequence,
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["latestUnreadMentionMessageId"] != messageID {
		t.Fatalf("latestUnreadMentionMessageId=%#v", decoded["latestUnreadMentionMessageId"])
	}
	if decoded["latestUnreadMentionSequence"] != float64(sequence) {
		t.Fatalf("latestUnreadMentionSequence=%#v", decoded["latestUnreadMentionSequence"])
	}
}

func TestPaginationLimits(t *testing.T) {
	if got, err := normalizeHistoryLimit(0); err != nil || got != DefaultHistoryLimit {
		t.Fatalf("history default=%d err=%v", got, err)
	}
	if _, err := normalizeHistoryLimit(MaximumHistoryLimit + 1); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("history overflow error=%v", err)
	}
	if got, err := normalizeSyncLimit(0); err != nil || got != DefaultSyncLimit {
		t.Fatalf("sync default=%d err=%v", got, err)
	}
	if _, err := normalizeSyncLimit(MaximumSyncLimit + 1); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("sync overflow error=%v", err)
	}
}

func stringPointer(value string) *string { return &value }
