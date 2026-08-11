package observability

import (
	"errors"
	"io"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetricsContractUsesBoundedLabelsAndExportsCoreSeries(t *testing.T) {
	metrics := New("api", "test")
	metrics.HTTPRequestStarted()
	metrics.HTTPRequestFinished("GET", "/api/v1/users/", 503, 125*time.Millisecond)
	metrics.ObservePostgresQuery("SELECT", 10*time.Millisecond, errors.New("postgres://secret@example.invalid/db"))
	metrics.ObserveRedis("publish", time.Millisecond, errors.New("redis://:secret@example.invalid"))
	metrics.WebSocketOpened("authenticated")
	metrics.WebSocketClosed("authenticated")
	metrics.RealtimePublishFailure("publish")
	metrics.RealtimeQueueDropped()
	metrics.PushJobStarted()
	metrics.PushJobFinished()
	metrics.PushRetry()
	metrics.PushFailed()
	metrics.ObservePushProvider("FCM", "auth_failure", 50*time.Millisecond)
	metrics.SetPushProviderConfigured("FCM", true)
	metrics.ObserveObjectStorage("stat", 25*time.Millisecond, errors.New("Authorization: secret"))
	metrics.ObserveSMTP(20*time.Millisecond, errors.New("password=secret"))
	metrics.WorkerHeartbeat(nil)
	metrics.SetWorkerReady(true)

	request := httptest.NewRequest("GET", "/metrics", nil)
	response := httptest.NewRecorder()
	metrics.Handler().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("metrics status=%d", response.Code)
	}
	body, err := io.ReadAll(response.Result().Body)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	for _, series := range []string{
		"dd_http_requests_total",
		"dd_http_request_duration_seconds",
		"dd_http_active_requests",
		"dd_postgres_queries_total",
		"dd_redis_operations_total",
		"dd_websocket_connections",
		"dd_realtime_publish_failures_total",
		"dd_outbox_backlog",
		"dd_push_jobs",
		"dd_push_retries_total",
		"dd_push_failed_total",
		"dd_push_provider_requests_total",
		"dd_push_provider_auth_failures_total",
		"dd_push_invalid_endpoint_ratio",
		"dd_object_storage_requests_total",
		"dd_smtp_send_total",
		"dd_worker_last_heartbeat_timestamp_seconds",
		"go_goroutines",
		"process_cpu_seconds_total",
	} {
		if !strings.Contains(text, series) {
			t.Fatalf("metrics output missing %q", series)
		}
	}
	for _, forbidden := range []string{"secret@example.invalid", "password=secret", "Authorization: secret", "postgres://", "redis://"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("metrics output leaked forbidden value %q", forbidden)
		}
	}
}

func TestBoundedMetricDimensionsFailClosed(t *testing.T) {
	if got := boundedMethod("BREW"); got != "OTHER" {
		t.Fatalf("boundedMethod=%q", got)
	}
	if got := boundedRoute("https://example.invalid/users/user-123?token=secret"); got != "other" {
		t.Fatalf("boundedRoute=%q", got)
	}
	if got := boundedProvider("provider-user-controlled"); got != "OTHER" {
		t.Fatalf("boundedProvider=%q", got)
	}
	if got := boundedPushResult("secret-error-text"); got != "failure" {
		t.Fatalf("boundedPushResult=%q", got)
	}
	if got := statusClass(503); got != "5xx" {
		t.Fatalf("statusClass=%q", got)
	}
}
