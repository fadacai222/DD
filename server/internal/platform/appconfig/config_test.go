package appconfig

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadDevelopmentDefaults(t *testing.T) {
	clearConfigEnvironment(t)

	config, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if config.Environment != EnvironmentDevelopment {
		t.Fatalf("Environment = %q, want %q", config.Environment, EnvironmentDevelopment)
	}
	if config.Port != 18473 {
		t.Fatalf("Port = %d, want 18473", config.Port)
	}
	if config.LiveKitPublicPort != 7880 {
		t.Fatalf("LiveKitPublicPort = %d, want 7880", config.LiveKitPublicPort)
	}
	if len(config.AllowedOrigins) == 0 || len(config.AllowedHTTPOrigins) == 0 {
		t.Fatal("development defaults must restrict origins to loopback patterns")
	}
}

func TestLoadProductionRejectsDangerousDefaults(t *testing.T) {
	tests := []struct {
		name      string
		env       map[string]string
		wantError string
	}{
		{
			name: "missing origins",
			env: map[string]string{
				"IM_ENV":             "production",
				"IM_PUBLIC_BASE_URL": "https://chat.example.com",
				"LIVEKIT_URL":        "wss://livekit.example.com",
				"LIVEKIT_API_KEY":    "prodkey",
				"LIVEKIT_API_SECRET": strings.Repeat("s", 32),
			},
			wantError: "IM_ALLOWED_ORIGINS",
		},
		{
			name: "wildcard websocket origin",
			env: map[string]string{
				"IM_ENV":                  "production",
				"IM_ALLOWED_ORIGINS":      "*",
				"IM_ALLOWED_HTTP_ORIGINS": "https://chat.example.com",
				"IM_PUBLIC_BASE_URL":      "https://chat.example.com",
				"LIVEKIT_URL":             "wss://livekit.example.com",
				"LIVEKIT_API_KEY":         "prodkey",
				"LIVEKIT_API_SECRET":      strings.Repeat("s", 32),
			},
			wantError: "wildcard",
		},
		{
			name: "wildcard http origin",
			env: map[string]string{
				"IM_ENV":                  "production",
				"IM_ALLOWED_ORIGINS":      "chat.example.com",
				"IM_ALLOWED_HTTP_ORIGINS": "*",
				"IM_PUBLIC_BASE_URL":      "https://chat.example.com",
				"LIVEKIT_URL":             "wss://livekit.example.com",
				"LIVEKIT_API_KEY":         "prodkey",
				"LIVEKIT_API_SECRET":      strings.Repeat("s", 32),
			},
			wantError: "wildcard",
		},
		{
			name: "weak livekit secret",
			env: map[string]string{
				"IM_ENV":                  "production",
				"IM_ALLOWED_ORIGINS":      "chat.example.com",
				"IM_ALLOWED_HTTP_ORIGINS": "https://chat.example.com",
				"IM_PUBLIC_BASE_URL":      "https://chat.example.com",
				"LIVEKIT_URL":             "wss://livekit.example.com",
				"LIVEKIT_API_KEY":         "prodkey",
				"LIVEKIT_API_SECRET":      "secret",
			},
			wantError: "LIVEKIT_API_SECRET",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			clearConfigEnvironment(t)
			for key, value := range test.env {
				t.Setenv(key, value)
			}

			_, err := Load()
			if err == nil || !strings.Contains(strings.ToLower(err.Error()), strings.ToLower(test.wantError)) {
				t.Fatalf("Load() error = %v, want containing %q", err, test.wantError)
			}
		})
	}
}

func TestLoadProductionRequiresExplicitPublicBaseURL(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_ENV", "production")
	t.Setenv("IM_ALLOWED_ORIGINS", "chat.example.com")
	t.Setenv("IM_ALLOWED_HTTP_ORIGINS", "https://chat.example.com")
	t.Setenv("LIVEKIT_URL", "wss://livekit.example.com")
	t.Setenv("LIVEKIT_API_KEY", "prodkey")
	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("s", 32))

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "IM_PUBLIC_BASE_URL") {
		t.Fatalf("Load() error = %v, want IM_PUBLIC_BASE_URL validation error", err)
	}
}

func TestLoadProductionRejectsPublicBaseURLPath(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_ENV", "production")
	t.Setenv("IM_PUBLIC_BASE_URL", "https://chat.example.com/prefix")
	t.Setenv("IM_ALLOWED_ORIGINS", "chat.example.com")
	t.Setenv("IM_ALLOWED_HTTP_ORIGINS", "https://chat.example.com")
	t.Setenv("LIVEKIT_URL", "wss://livekit.example.com")
	t.Setenv("LIVEKIT_API_KEY", "prodkey")
	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("s", 32))

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "IM_PUBLIC_BASE_URL") {
		t.Fatalf("Load() error = %v, want IM_PUBLIC_BASE_URL path validation error", err)
	}
}

func TestLoadRejectsOversizedInstanceName(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_INSTANCE_NAME", strings.Repeat("D", 81))

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "IM_INSTANCE_NAME") {
		t.Fatalf("Load() error = %v, want IM_INSTANCE_NAME validation error", err)
	}
}

func TestLoadDevelopmentDefaultsRegistrationOpen(t *testing.T) {
	clearConfigEnvironment(t)

	config, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if config.RegistrationMode != RegistrationOpen {
		t.Fatalf("RegistrationMode = %q, want %q", config.RegistrationMode, RegistrationOpen)
	}
}

func TestLoadProductionDefaultsRegistrationClosed(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_ENV", "production")
	t.Setenv("IM_PUBLIC_BASE_URL", "https://chat.example.com")
	t.Setenv("IM_ALLOWED_ORIGINS", "chat.example.com")
	t.Setenv("IM_ALLOWED_HTTP_ORIGINS", "https://chat.example.com")
	t.Setenv("LIVEKIT_URL", "wss://livekit.example.com")
	t.Setenv("LIVEKIT_API_KEY", "prodkey")
	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("s", 32))
	t.Setenv("DATABASE_URL", "postgres://dd:secret@db.example.com/dd")
	t.Setenv("AUTH_TOKEN_SECRET", strings.Repeat("a", 32))

	config, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if config.RegistrationMode != RegistrationClosed {
		t.Fatalf("RegistrationMode = %q, want %q", config.RegistrationMode, RegistrationClosed)
	}
}

func TestLoadRejectsInvalidRegistrationMode(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_REGISTRATION_MODE", "surprise")

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "IM_REGISTRATION_MODE") {
		t.Fatalf("Load() error = %v, want registration mode validation error", err)
	}
}

func TestLoadProductionOpenRegistrationRequiresMailSecurity(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_ENV", "production")
	t.Setenv("IM_PUBLIC_BASE_URL", "https://chat.example.com")
	t.Setenv("IM_ALLOWED_ORIGINS", "chat.example.com")
	t.Setenv("IM_ALLOWED_HTTP_ORIGINS", "https://chat.example.com")
	t.Setenv("LIVEKIT_URL", "wss://livekit.example.com")
	t.Setenv("LIVEKIT_API_KEY", "prodkey")
	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("s", 32))
	t.Setenv("DATABASE_URL", "postgres://dd:secret@db.example.com/dd")
	t.Setenv("AUTH_TOKEN_SECRET", strings.Repeat("a", 32))
	t.Setenv("IM_REGISTRATION_MODE", "open")

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "EMAIL_CODE_PEPPER") {
		t.Fatalf("Load() error = %v, want email code pepper requirement", err)
	}

	t.Setenv("EMAIL_CODE_PEPPER", strings.Repeat("p", 32))
	_, err = Load()
	if err == nil || !strings.Contains(err.Error(), "SMTP_HOST") {
		t.Fatalf("Load() error = %v, want SMTP requirement", err)
	}
}

func TestLoadProductionRequiresDatabaseURL(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_ENV", "production")
	t.Setenv("IM_PUBLIC_BASE_URL", "https://chat.example.com")
	t.Setenv("IM_ALLOWED_ORIGINS", "chat.example.com")
	t.Setenv("IM_ALLOWED_HTTP_ORIGINS", "https://chat.example.com")
	t.Setenv("LIVEKIT_URL", "wss://livekit.example.com")
	t.Setenv("LIVEKIT_API_KEY", "prodkey")
	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("s", 32))

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "DATABASE_URL") {
		t.Fatalf("Load() error = %v, want DATABASE_URL validation error", err)
	}
}

func TestLoadReadsSecretFileAndRejectsAmbiguousSecretSources(t *testing.T) {
	clearConfigEnvironment(t)
	secretPath := filepath.Join(t.TempDir(), "livekit-secret")
	if err := os.WriteFile(secretPath, []byte(strings.Repeat("x", 40)+"\n"), 0o600); err != nil {
		t.Fatalf("write secret file: %v", err)
	}

	t.Setenv("LIVEKIT_API_SECRET_FILE", secretPath)
	config, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if config.LiveKitAPISecret != strings.Repeat("x", 40) {
		t.Fatalf("LiveKitAPISecret was not trimmed/read from file")
	}

	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("y", 40))
	_, err = Load()
	if err == nil || !strings.Contains(err.Error(), "both") {
		t.Fatalf("Load() error = %v, want ambiguous secret source error", err)
	}
}

func TestLoadRejectsInvalidPorts(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("IM_PORT", "5000")

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "IM_PORT") {
		t.Fatalf("Load() error = %v, want IM_PORT validation error", err)
	}
}

func clearConfigEnvironment(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"IM_ENV",
		"IM_PORT",
		"IM_ALLOWED_ORIGINS",
		"IM_ALLOWED_HTTP_ORIGINS",
		"IM_PUBLIC_BASE_URL",
		"IM_INSTANCE_NAME",
		"LIVEKIT_URL",
		"LIVEKIT_PUBLIC_PORT",
		"LIVEKIT_API_KEY",
		"LIVEKIT_API_KEY_FILE",
		"LIVEKIT_API_SECRET",
		"LIVEKIT_API_SECRET_FILE",
		"DATABASE_URL",
		"DATABASE_URL_FILE",
		"REDIS_URL",
		"REDIS_URL_FILE",
		"AUTH_TOKEN_SECRET",
		"AUTH_TOKEN_SECRET_FILE",
		"IM_REGISTRATION_MODE",
		"EMAIL_CODE_PEPPER",
		"EMAIL_CODE_PEPPER_FILE",
		"SMTP_HOST",
		"SMTP_PORT",
		"SMTP_FROM",
		"SMTP_USERNAME",
		"SMTP_PASSWORD",
		"SMTP_PASSWORD_FILE",
		"SMTP_REQUIRE_TLS",
	} {
		t.Setenv(key, "")
	}
}
