package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"example.com/selfhosted-im/server/internal/platform/appconfig"
)

func TestGroupsConfigFromAppConfigUsesResolvedLiveKitSecretFiles(t *testing.T) {
	t.Setenv("IM_ENV", "production")
	t.Setenv("IM_PUBLIC_BASE_URL", "https://api.example.com")
	t.Setenv("IM_ALLOWED_ORIGINS", "app.example.com")
	t.Setenv("IM_ALLOWED_HTTP_ORIGINS", "https://app.example.com")
	t.Setenv("IM_REGISTRATION_MODE", "closed")
	t.Setenv("LIVEKIT_URL", "wss://media.example.com")
	t.Setenv("LIVEKIT_API_KEY", "")
	t.Setenv("LIVEKIT_API_SECRET", "")
	t.Setenv("DATABASE_URL_FILE", "")
	t.Setenv("DATABASE_URL", "postgres://dd:password@db.example.com/dd")
	t.Setenv("AUTH_TOKEN_SECRET_FILE", "")
	t.Setenv("AUTH_TOKEN_SECRET", strings.Repeat("a", 32))
	t.Setenv("ADMIN_SECURITY_SECRET_FILE", "")
	t.Setenv("ADMIN_SECURITY_SECRET", strings.Repeat("m", 32))
	t.Setenv("DD_GROUP_CALL_MAX_PARTICIPANTS", "7")

	secretDir := t.TempDir()
	keyPath := filepath.Join(secretDir, "livekit-key")
	secretPath := filepath.Join(secretDir, "livekit-secret")
	if err := os.WriteFile(keyPath, []byte("group-call-key\n"), 0o600); err != nil {
		t.Fatalf("write key file: %v", err)
	}
	resolvedSecret := strings.Repeat("s", 40)
	if err := os.WriteFile(secretPath, []byte(resolvedSecret+"\n"), 0o600); err != nil {
		t.Fatalf("write secret file: %v", err)
	}
	t.Setenv("LIVEKIT_API_KEY_FILE", keyPath)
	t.Setenv("LIVEKIT_API_SECRET_FILE", secretPath)

	config, err := appconfig.Load()
	if err != nil {
		t.Fatalf("appconfig.Load() error = %v", err)
	}
	groupConfig := groupsConfigFromAppConfig(config, nil)
	if groupConfig.LiveKitURL != "wss://media.example.com" {
		t.Fatalf("LiveKitURL = %q", groupConfig.LiveKitURL)
	}
	if groupConfig.LiveKitAPIKey != "group-call-key" {
		t.Fatalf("LiveKitAPIKey was not injected from resolved secret file")
	}
	if groupConfig.LiveKitAPISecret != resolvedSecret {
		t.Fatalf("LiveKitAPISecret was not injected from resolved secret file")
	}
	if groupConfig.GroupCallMaxParticipants != 7 {
		t.Fatalf("GroupCallMaxParticipants = %d, want 7", groupConfig.GroupCallMaxParticipants)
	}
}
