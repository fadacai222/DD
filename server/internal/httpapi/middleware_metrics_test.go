package httpapi

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type captureRuntimeMetrics struct {
	started int
	ended   int
	method  string
	route   string
	status  int
}

func (metrics *captureRuntimeMetrics) HTTPRequestStarted() { metrics.started++ }
func (metrics *captureRuntimeMetrics) HTTPRequestFinished(method, route string, status int, _ time.Duration) {
	metrics.ended++
	metrics.method = method
	metrics.route = route
	metrics.status = status
}
func (*captureRuntimeMetrics) SetDependencyHealth(string, bool) {}
func (*captureRuntimeMetrics) WebSocketOpened(string)           {}
func (*captureRuntimeMetrics) WebSocketClosed(string)           {}
func (*captureRuntimeMetrics) RealtimePublishFailure(string)    {}
func (*captureRuntimeMetrics) RealtimeQueueDropped()            {}
func (*captureRuntimeMetrics) RedisReconnect()                  {}

func TestAccessLogMetricsUseServeMuxPattern(t *testing.T) {
	metrics := &captureRuntimeMetrics{}
	mux := http.NewServeMux()
	mux.HandleFunc("/users/{id}", func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusNoContent)
	})
	handler := accessLogMiddleware(slog.New(slog.NewTextHandler(io.Discard, nil)), "test", metrics, mux)
	request := httptest.NewRequest(http.MethodGet, "/users/private-user-id", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	if metrics.started != 1 || metrics.ended != 1 {
		t.Fatalf("metric lifecycle started=%d ended=%d", metrics.started, metrics.ended)
	}
	if metrics.route != "/users/{id}" {
		t.Fatalf("metric route=%q; raw path must not be used", metrics.route)
	}
	if metrics.method != http.MethodGet || metrics.status != http.StatusNoContent {
		t.Fatalf("metric method=%q status=%d", metrics.method, metrics.status)
	}
}

func TestAccessLogMetricsFinishOnPanic(t *testing.T) {
	metrics := &captureRuntimeMetrics{}
	mux := http.NewServeMux()
	mux.HandleFunc("/panic", func(http.ResponseWriter, *http.Request) { panic("boom") })
	handler := accessLogMiddleware(slog.New(slog.NewTextHandler(io.Discard, nil)), "test", metrics, mux)

	func() {
		defer func() { _ = recover() }()
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/panic", nil))
	}()

	if metrics.started != 1 || metrics.ended != 1 || metrics.status != http.StatusInternalServerError {
		t.Fatalf("panic metric lifecycle started=%d ended=%d status=%d", metrics.started, metrics.ended, metrics.status)
	}
}
