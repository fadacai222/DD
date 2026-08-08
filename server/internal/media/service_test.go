package media

import (
	"strings"
	"testing"
)

func TestValidateUploadInputByPurpose(t *testing.T) {
	tests := []struct {
		name    string
		input   CreateUploadInput
		wantErr error
	}{
		{
			name: "chat image jpeg",
			input: CreateUploadInput{FileName: "photo.jpg", Size: 2 * 1024 * 1024, MIMEType: "image/jpeg", SHA256: strings.Repeat("a", 64), Purpose: PurposeChatImage},
		},
		{
			name: "gif is explicit purpose",
			input: CreateUploadInput{FileName: "fun.gif", Size: 3 * 1024 * 1024, MIMEType: "image/gif", SHA256: strings.Repeat("b", 64), Purpose: PurposeGIF},
		},
		{
			name: "image rejects executable mime",
			input: CreateUploadInput{FileName: "photo.exe", Size: 1024, MIMEType: "application/x-msdownload", SHA256: strings.Repeat("c", 64), Purpose: PurposeChatImage},
			wantErr: ErrInvalidInput,
		},
		{
			name: "voice rejects oversized",
			input: CreateUploadInput{FileName: "voice.m4a", Size: maxVoiceBytes + 1, MIMEType: "audio/mp4", SHA256: strings.Repeat("d", 64), Purpose: PurposeChatVoice},
			wantErr: ErrQuotaExceeded,
		},
		{
			name: "sha must be lowercase hex",
			input: CreateUploadInput{FileName: "photo.jpg", Size: 1024, MIMEType: "image/jpeg", SHA256: strings.Repeat("Z", 64), Purpose: PurposeChatImage},
			wantErr: ErrInvalidInput,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateUploadInput(test.input)
			if test.wantErr == nil && err != nil {
				t.Fatalf("validateUploadInput() error = %v", err)
			}
			if test.wantErr != nil && err != test.wantErr {
				t.Fatalf("validateUploadInput() error = %v, want %v", err, test.wantErr)
			}
		})
	}
}

func TestNewStorageKeyIsOpaqueAndPurposePartitioned(t *testing.T) {
	first, err := newStorageKey(PurposeChatImage)
	if err != nil {
		t.Fatalf("newStorageKey() error = %v", err)
	}
	second, err := newStorageKey(PurposeChatImage)
	if err != nil {
		t.Fatalf("newStorageKey() second error = %v", err)
	}
	if first == second {
		t.Fatal("storage keys must be random")
	}
	if !strings.HasPrefix(first, "chat-image/") {
		t.Fatalf("storage key prefix = %q", first)
	}
	if strings.Contains(first, "photo") || strings.Contains(first, "user") {
		t.Fatalf("storage key leaks source metadata: %q", first)
	}
	parts := strings.Split(first, "/")
	if len(parts) != 4 || len(parts[3]) < 32 {
		t.Fatalf("storage key shape = %q", first)
	}
}
