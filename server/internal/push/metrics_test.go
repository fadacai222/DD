package push

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestProviderMetricResult(t *testing.T) {
	tests := []struct {
		name     string
		provider string
		result   ProviderResult
		err      error
		want     string
	}{
		{name: "success", provider: ProviderFCM, want: "success"},
		{name: "invalid token", provider: ProviderFCM, result: ProviderResult{InvalidToken: true}, err: errors.New("unregistered"), want: "invalid_token"},
		{name: "retryable", provider: ProviderFCM, err: fmt.Errorf("%w: temporary", ErrRetryable), want: "retryable"},
		{name: "fcm oauth revoked", provider: ProviderFCM, err: errors.New("FCM OAuth HTTP 403: invalid_grant"), want: "auth_failure"},
		{name: "apns key rejected", provider: ProviderAPNS, err: errors.New("APNs HTTP 403: InvalidProviderToken"), want: "auth_failure"},
		{name: "unified push forbidden is endpoint failure", provider: ProviderUnifiedPush, err: errors.New("UnifiedPush HTTP 403: forbidden"), want: "failure"},
		{name: "permanent provider error", provider: ProviderFCM, err: errors.New("FCM HTTP 400: malformed request"), want: "failure"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := providerMetricResult(test.provider, test.result, test.err); got != test.want {
				t.Fatalf("providerMetricResult=%q want=%q", got, test.want)
			}
		})
	}
}

func TestCleanupInvalidEndpointsRejectsUnsafeRetention(t *testing.T) {
	service := &Service{}
	if _, err := service.CleanupInvalidEndpoints(t.Context(), 100, time.Hour); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("CleanupInvalidEndpoints error=%v want ErrInvalidInput", err)
	}
}
