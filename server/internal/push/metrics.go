package push

import (
	"errors"
	"strings"
	"time"
)

type Observer interface {
	PushJobStarted()
	PushJobFinished()
	PushRetry()
	PushFailed()
	ObservePushProvider(provider, result string, duration time.Duration)
	SetPushProviderConfigured(provider string, configured bool)
}

func providerMetricResult(provider string, result ProviderResult, err error) string {
	if err == nil {
		return "success"
	}
	if result.InvalidToken {
		return "invalid_token"
	}
	if isProviderAuthFailure(provider, err) {
		return "auth_failure"
	}
	if errors.Is(err, ErrRetryable) || errors.Is(err, ErrProviderUnavailable) {
		return "retryable"
	}
	return "failure"
}

func isProviderAuthFailure(provider string, err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToUpper(err.Error())
	switch strings.ToUpper(strings.TrimSpace(provider)) {
	case ProviderFCM:
		return strings.Contains(text, "FCM OAUTH HTTP 400") ||
			strings.Contains(text, "FCM OAUTH HTTP 401") ||
			strings.Contains(text, "FCM OAUTH HTTP 403") ||
			strings.Contains(text, "FCM HTTP 401") ||
			strings.Contains(text, "FCM HTTP 403")
	case ProviderAPNS:
		return strings.Contains(text, "APNS HTTP 403") ||
			strings.Contains(text, "INVALIDPROVIDERTOKEN") ||
			strings.Contains(text, "EXPIREDPROVIDERTOKEN")
	default:
		return false
	}
}
