package appconfig

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	defaultPort                     = 18473
	defaultLiveKitPublicPort        = 7880
	defaultGroupCallMaxParticipants = 32
	maximumGroupCallParticipants    = 500
	minimumProductionSecret         = 32
)

type Environment string

const (
	EnvironmentDevelopment Environment = "development"
	EnvironmentTest        Environment = "test"
	EnvironmentProduction  Environment = "production"
)

type RegistrationMode string

const (
	RegistrationOpen     RegistrationMode = "open"
	RegistrationInvite   RegistrationMode = "invite"
	RegistrationApproval RegistrationMode = "approval"
	RegistrationClosed   RegistrationMode = "closed"
)

type Config struct {
	Environment         Environment
	Port                int
	PublicBaseURL       string
	InstanceName        string
	AllowedOrigins      []string
	AllowedHTTPOrigins  []string
	LiveKitURL          string
	LiveKitPublicPort   int
	GroupCallLimit      int
	LiveKitAPIKey       string
	LiveKitAPISecret    string
	DatabaseURL         string
	RedisURL            string
	MediaS3Endpoint     string
	MediaS3Bucket       string
	MediaS3Region       string
	MediaS3AccessKey    string
	MediaS3SecretKey    string
	VoiceTranscriptionEndpoint   string
	VoiceTranscriptionModel      string
	VoiceTranscriptionCredential string
	TelegramBotToken    string
	AuthTokenSecret     string
	AdminSecuritySecret string
	RegistrationMode    RegistrationMode
	EmailCodePepper     string
	SMTPHost            string
	SMTPPort            int
	SMTPFrom            string
	SMTPUsername        string
	SMTPPassword        string
	SMTPRequireTLS      bool
}

func Load() (Config, error) {
	environment, err := parseEnvironment(os.Getenv("IM_ENV"))
	if err != nil {
		return Config{}, err
	}

	port, err := parsePort("IM_PORT", os.Getenv("IM_PORT"), defaultPort, true)
	if err != nil {
		return Config{}, err
	}
	liveKitPublicPort, err := parsePort("LIVEKIT_PUBLIC_PORT", os.Getenv("LIVEKIT_PUBLIC_PORT"), defaultLiveKitPublicPort, false)
	if err != nil {
		return Config{}, err
	}
	groupCallMaxParticipants := parseGroupCallMaxParticipants(os.Getenv("DD_GROUP_CALL_MAX_PARTICIPANTS"))

	allowedOrigins := splitNonEmpty(os.Getenv("IM_ALLOWED_ORIGINS"))
	allowedHTTPOrigins := splitNonEmpty(os.Getenv("IM_ALLOWED_HTTP_ORIGINS"))
	if environment != EnvironmentProduction {
		if len(allowedOrigins) == 0 {
			allowedOrigins = []string{"localhost:*", "127.0.0.1:*", "10.0.2.2:*"}
		}
		if len(allowedHTTPOrigins) == 0 {
			allowedHTTPOrigins = []string{"http://localhost:*", "http://127.0.0.1:*"}
		}
	}

	liveKitAPIKey, err := ReadSecret("LIVEKIT_API_KEY")
	if err != nil {
		return Config{}, err
	}
	liveKitAPISecret, err := ReadSecret("LIVEKIT_API_SECRET")
	if err != nil {
		return Config{}, err
	}
	databaseURL, err := ReadSecret("DATABASE_URL")
	if err != nil {
		return Config{}, err
	}
	redisURL, err := ReadSecret("REDIS_URL")
	if err != nil {
		return Config{}, err
	}
	mediaS3AccessKey, err := ReadSecret("MEDIA_S3_ACCESS_KEY")
	if err != nil {
		return Config{}, err
	}
	mediaS3SecretKey, err := ReadSecret("MEDIA_S3_SECRET_KEY")
	if err != nil {
		return Config{}, err
	}
	voiceTranscriptionCredential, err := ReadSecret("VOICE_TRANSCRIPTION_CREDENTIAL")
	if err != nil {
		return Config{}, err
	}
	telegramBotToken, err := ReadSecret("TELEGRAM_BOT_TOKEN")
	if err != nil {
		return Config{}, err
	}
	authTokenSecret, err := ReadSecret("AUTH_TOKEN_SECRET")
	if err != nil {
		return Config{}, err
	}
	adminSecuritySecret, err := ReadSecret("ADMIN_SECURITY_SECRET")
	if err != nil {
		return Config{}, err
	}
	emailCodePepper, err := ReadSecret("EMAIL_CODE_PEPPER")
	if err != nil {
		return Config{}, err
	}
	smtpPassword, err := ReadSecret("SMTP_PASSWORD")
	if err != nil {
		return Config{}, err
	}

	registrationMode, err := parseRegistrationMode(os.Getenv("IM_REGISTRATION_MODE"), environment)
	if err != nil {
		return Config{}, err
	}
	smtpPortDefault := 11025
	if environment == EnvironmentProduction {
		smtpPortDefault = 587
	}
	smtpPort, err := parsePort("SMTP_PORT", os.Getenv("SMTP_PORT"), smtpPortDefault, false)
	if err != nil {
		return Config{}, err
	}
	smtpRequireTLS, err := parseBool("SMTP_REQUIRE_TLS", os.Getenv("SMTP_REQUIRE_TLS"), environment == EnvironmentProduction)
	if err != nil {
		return Config{}, err
	}
	smtpHost := strings.TrimSpace(os.Getenv("SMTP_HOST"))
	smtpFrom := strings.TrimSpace(os.Getenv("SMTP_FROM"))
	if environment != EnvironmentProduction && strings.TrimSpace(databaseURL) != "" && registrationMode != RegistrationClosed {
		if smtpHost == "" {
			smtpHost = "127.0.0.1"
		}
		if smtpFrom == "" {
			smtpFrom = "noreply@dd.local"
		}
	}

	instanceName := strings.TrimSpace(os.Getenv("IM_INSTANCE_NAME"))
	if instanceName == "" {
		instanceName = "DD"
	}

	config := Config{
		Environment:         environment,
		Port:                port,
		PublicBaseURL:       strings.TrimRight(strings.TrimSpace(os.Getenv("IM_PUBLIC_BASE_URL")), "/"),
		InstanceName:        instanceName,
		AllowedOrigins:      allowedOrigins,
		AllowedHTTPOrigins:  allowedHTTPOrigins,
		LiveKitURL:          strings.TrimSpace(os.Getenv("LIVEKIT_URL")),
		LiveKitPublicPort:   liveKitPublicPort,
		GroupCallLimit:      groupCallMaxParticipants,
		LiveKitAPIKey:       liveKitAPIKey,
		LiveKitAPISecret:    liveKitAPISecret,
		DatabaseURL:         databaseURL,
		RedisURL:            redisURL,
		MediaS3Endpoint:     strings.TrimRight(strings.TrimSpace(os.Getenv("MEDIA_S3_ENDPOINT")), "/"),
		MediaS3Bucket:       strings.TrimSpace(os.Getenv("MEDIA_S3_BUCKET")),
		MediaS3Region:       strings.TrimSpace(os.Getenv("MEDIA_S3_REGION")),
		MediaS3AccessKey:    mediaS3AccessKey,
		MediaS3SecretKey:    mediaS3SecretKey,
		VoiceTranscriptionEndpoint: strings.TrimSpace(os.Getenv("VOICE_TRANSCRIPTION_ENDPOINT")),
		VoiceTranscriptionModel: strings.TrimSpace(os.Getenv("VOICE_TRANSCRIPTION_MODEL")),
		VoiceTranscriptionCredential: voiceTranscriptionCredential,
		TelegramBotToken:    telegramBotToken,
		AuthTokenSecret:     authTokenSecret,
		AdminSecuritySecret: adminSecuritySecret,
		RegistrationMode:    registrationMode,
		EmailCodePepper:     emailCodePepper,
		SMTPHost:            smtpHost,
		SMTPPort:            smtpPort,
		SMTPFrom:            smtpFrom,
		SMTPUsername:        strings.TrimSpace(os.Getenv("SMTP_USERNAME")),
		SMTPPassword:        smtpPassword,
		SMTPRequireTLS:      smtpRequireTLS,
	}
	if err := config.Validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func (config Config) Validate() error {
	if utf8.RuneCountInString(strings.TrimSpace(config.InstanceName)) > 80 {
		return errors.New("IM_INSTANCE_NAME must contain at most 80 characters")
	}
	if strings.TrimSpace(config.VoiceTranscriptionEndpoint) != "" && strings.TrimSpace(config.VoiceTranscriptionModel) == "" {
		return errors.New("VOICE_TRANSCRIPTION_MODEL is required when VOICE_TRANSCRIPTION_ENDPOINT is configured")
	}
	if strings.TrimSpace(config.VoiceTranscriptionEndpoint) == "" && strings.TrimSpace(config.VoiceTranscriptionModel) != "" {
		return errors.New("VOICE_TRANSCRIPTION_ENDPOINT is required when VOICE_TRANSCRIPTION_MODEL is configured")
	}
	if strings.TrimSpace(config.MediaS3Endpoint) != "" {
		if strings.TrimSpace(config.MediaS3Bucket) == "" {
			return errors.New("MEDIA_S3_BUCKET is required when MEDIA_S3_ENDPOINT is configured")
		}
		if strings.TrimSpace(config.MediaS3AccessKey) == "" || strings.TrimSpace(config.MediaS3SecretKey) == "" {
			return errors.New("MEDIA_S3_ACCESS_KEY and MEDIA_S3_SECRET_KEY are required when MEDIA_S3_ENDPOINT is configured")
		}
	}
	if strings.TrimSpace(config.DatabaseURL) != "" {
		if len(config.AuthTokenSecret) < minimumProductionSecret {
			return fmt.Errorf("AUTH_TOKEN_SECRET must contain at least %d characters when DATABASE_URL is configured", minimumProductionSecret)
		}
		if len(config.AdminSecuritySecret) < minimumProductionSecret {
			return fmt.Errorf("ADMIN_SECURITY_SECRET or ADMIN_SECURITY_SECRET_FILE must contain at least %d bytes when DATABASE_URL is configured", minimumProductionSecret)
		}
	}
	if strings.TrimSpace(config.DatabaseURL) != "" && config.RegistrationMode != RegistrationClosed {
		if len(config.EmailCodePepper) < 32 {
			return errors.New("EMAIL_CODE_PEPPER must contain at least 32 characters when registration is enabled")
		}
		if strings.TrimSpace(config.SMTPHost) == "" {
			return errors.New("SMTP_HOST is required when registration is enabled")
		}
		if strings.TrimSpace(config.SMTPFrom) == "" {
			return errors.New("SMTP_FROM is required when registration is enabled")
		}
		if config.SMTPUsername != "" && config.SMTPPassword == "" {
			return errors.New("SMTP_PASSWORD or SMTP_PASSWORD_FILE is required when SMTP_USERNAME is configured")
		}
	}
	if config.Environment != EnvironmentProduction {
		return nil
	}
	if config.PublicBaseURL == "" {
		return errors.New("IM_PUBLIC_BASE_URL is required in production")
	}
	publicBaseURL, err := url.Parse(config.PublicBaseURL)
	if err != nil || publicBaseURL.Scheme != "https" || publicBaseURL.Host == "" || publicBaseURL.User != nil || publicBaseURL.RawQuery != "" || publicBaseURL.Fragment != "" || (publicBaseURL.Path != "" && publicBaseURL.Path != "/") {
		return errors.New("IM_PUBLIC_BASE_URL must be an origin-only https:// URL without credentials, path, query, or fragment in production")
	}
	if len(config.AllowedOrigins) == 0 {
		return errors.New("IM_ALLOWED_ORIGINS is required in production")
	}
	if len(config.AllowedHTTPOrigins) == 0 {
		return errors.New("IM_ALLOWED_HTTP_ORIGINS is required in production")
	}
	if containsGlobalWildcard(config.AllowedOrigins) {
		return errors.New("IM_ALLOWED_ORIGINS must not contain a global wildcard in production")
	}
	if containsGlobalWildcard(config.AllowedHTTPOrigins) {
		return errors.New("IM_ALLOWED_HTTP_ORIGINS must not contain a global wildcard in production")
	}
	for _, origin := range config.AllowedHTTPOrigins {
		parsed, err := url.Parse(origin)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
			return fmt.Errorf("IM_ALLOWED_HTTP_ORIGINS must contain only https origins in production: %q", origin)
		}
	}
	if strings.TrimSpace(config.LiveKitURL) == "" || strings.EqualFold(strings.TrimSpace(config.LiveKitURL), "auto") {
		return errors.New("LIVEKIT_URL must be an explicit wss:// URL in production")
	}
	liveKitURL, err := url.Parse(config.LiveKitURL)
	if err != nil || liveKitURL.Scheme != "wss" || liveKitURL.Host == "" {
		return errors.New("LIVEKIT_URL must be an explicit wss:// URL in production")
	}
	if strings.TrimSpace(config.LiveKitAPIKey) == "" {
		return errors.New("LIVEKIT_API_KEY is required in production")
	}
	if len(config.LiveKitAPISecret) < minimumProductionSecret {
		return fmt.Errorf("LIVEKIT_API_SECRET must contain at least %d characters in production", minimumProductionSecret)
	}
	if strings.TrimSpace(config.DatabaseURL) == "" {
		return errors.New("DATABASE_URL or DATABASE_URL_FILE is required in production")
	}
	databaseURL, err := url.Parse(config.DatabaseURL)
	if err != nil || (databaseURL.Scheme != "postgres" && databaseURL.Scheme != "postgresql") || databaseURL.Host == "" {
		return errors.New("DATABASE_URL must be a postgres:// or postgresql:// URL in production")
	}
	if config.RegistrationMode != RegistrationClosed {
		if !config.SMTPRequireTLS {
			return errors.New("SMTP_REQUIRE_TLS must be true in production when registration is enabled")
		}
	}
	return nil
}

func parseRegistrationMode(raw string, environment Environment) (RegistrationMode, error) {
	value := RegistrationMode(strings.ToLower(strings.TrimSpace(raw)))
	if value == "" {
		if environment == EnvironmentProduction {
			return RegistrationClosed, nil
		}
		return RegistrationOpen, nil
	}
	switch value {
	case RegistrationOpen, RegistrationInvite, RegistrationApproval, RegistrationClosed:
		return value, nil
	default:
		return "", errors.New("IM_REGISTRATION_MODE must be open, invite, approval, or closed")
	}
}

func parseBool(name, raw string, defaultValue bool) (bool, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return defaultValue, nil
	}
	value, err := strconv.ParseBool(raw)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false", name)
	}
	return value, nil
}

func parseEnvironment(raw string) (Environment, error) {
	switch Environment(strings.ToLower(strings.TrimSpace(raw))) {
	case "", EnvironmentDevelopment:
		return EnvironmentDevelopment, nil
	case EnvironmentTest:
		return EnvironmentTest, nil
	case EnvironmentProduction:
		return EnvironmentProduction, nil
	default:
		return "", fmt.Errorf("IM_ENV must be development, test, or production")
	}
}

func parseGroupCallMaxParticipants(raw string) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return defaultGroupCallMaxParticipants
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 2 || value > maximumGroupCallParticipants {
		return defaultGroupCallMaxParticipants
	}
	return value
}

func parsePort(name, raw string, defaultValue int, requireFiveDigits bool) (int, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return defaultValue, nil
	}
	value, err := strconv.Atoi(raw)
	minimum := 1
	if requireFiveDigits {
		minimum = 10000
	}
	if err != nil || value < minimum || value > 65535 {
		if requireFiveDigits {
			return 0, fmt.Errorf("%s must be a number between 10000 and 65535", name)
		}
		return 0, fmt.Errorf("%s must be a number between 1 and 65535", name)
	}
	return value, nil
}

func ReadSecret(name string) (string, error) {
	direct := strings.TrimSpace(os.Getenv(name))
	filePath := strings.TrimSpace(os.Getenv(name + "_FILE"))
	if direct != "" && filePath != "" {
		return "", fmt.Errorf("%s and %s_FILE must not both be set", name, name)
	}
	if filePath == "" {
		return direct, nil
	}
	contents, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read %s_FILE: %w", name, err)
	}
	return strings.TrimSpace(string(contents)), nil
}

func splitNonEmpty(raw string) []string {
	parts := strings.Split(raw, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		value := strings.TrimSpace(part)
		if value != "" {
			values = append(values, value)
		}
	}
	return values
}

func containsGlobalWildcard(values []string) bool {
	for _, value := range values {
		if strings.TrimSpace(value) == "*" {
			return true
		}
	}
	return false
}
