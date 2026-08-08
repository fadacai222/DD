package messaging

import (
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
		{name: "unsupported type", input: SendMessageInput{ClientMessageID: "client-0004", Type: "IMAGE", Content: &TextContent{Text: "x"}}, wantErr: ErrUnsupportedType},
		{name: "bad reply uuid", input: SendMessageInput{ClientMessageID: "client-0005", Type: "TEXT", Content: &TextContent{Text: "x"}, ReplyToMessageID: stringPointer("not-a-uuid")}, wantErr: ErrInvalidInput},
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
			if got.Type != "TEXT" || got.Content == nil || got.Content.Text != tt.input.Content.Text {
				t.Fatalf("normalized=%#v", got)
			}
		})
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
