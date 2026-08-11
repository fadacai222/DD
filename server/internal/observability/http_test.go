package observability

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestOperationalHandlerReadinessDoesNotLeakDependencyErrors(t *testing.T) {
	metrics := New("worker", "test")
	handler := NewOperationalHandler(metrics.Handler(), map[string]ReadinessCheck{
		"postgres": func(context.Context) error { return nil },
		"redis": func(context.Context) error {
			return errors.New("redis://:super-secret@example.invalid/0")
		},
	})

	request := httptest.NewRequest(http.MethodGet, "/ready", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("ready status=%d", response.Code)
	}
	body := response.Body.String()
	if !strings.Contains(body, `"postgres":"ok"`) || !strings.Contains(body, `"redis":"failed"`) {
		t.Fatalf("ready body=%s", body)
	}
	if strings.Contains(body, "super-secret") || strings.Contains(body, "redis://") {
		t.Fatalf("readiness leaked dependency error: %s", body)
	}
}

func TestOperationalHandlerMetricsAndLive(t *testing.T) {
	metrics := New("api", "test")
	handler := NewOperationalHandler(metrics.Handler(), nil)

	liveRequest := httptest.NewRequest(http.MethodGet, "/live", nil)
	liveResponse := httptest.NewRecorder()
	handler.ServeHTTP(liveResponse, liveRequest)
	if liveResponse.Code != http.StatusOK {
		t.Fatalf("live status=%d", liveResponse.Code)
	}

	metricsRequest := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	metricsResponse := httptest.NewRecorder()
	handler.ServeHTTP(metricsResponse, metricsRequest)
	if metricsResponse.Code != http.StatusOK || !strings.Contains(metricsResponse.Body.String(), "dd_service_info") {
		t.Fatalf("metrics status=%d body=%s", metricsResponse.Code, metricsResponse.Body.String())
	}
}
