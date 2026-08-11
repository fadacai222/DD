package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"strconv"
	"time"
)

const requestIDHeader = "X-Request-ID"

type requestContextKey struct{}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (recorder *statusRecorder) WriteHeader(status int) {
	if recorder.status != 0 {
		return
	}
	recorder.status = status
	recorder.ResponseWriter.WriteHeader(status)
}

func (recorder *statusRecorder) Write(data []byte) (int, error) {
	if recorder.status == 0 {
		recorder.WriteHeader(http.StatusOK)
	}
	written, err := recorder.ResponseWriter.Write(data)
	recorder.bytes += written
	return written, err
}

func (recorder *statusRecorder) Unwrap() http.ResponseWriter {
	return recorder.ResponseWriter
}

func requestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requestID := newRequestID()
		response.Header().Set(requestIDHeader, requestID)
		ctx := context.WithValue(request.Context(), requestContextKey{}, requestID)
		next.ServeHTTP(response, request.WithContext(ctx))
	})
}

func accessLogMiddleware(logger *slog.Logger, version string, metrics RuntimeMetrics, next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		started := time.Now()
		if metrics != nil {
			metrics.HTTPRequestStarted()
		}
		recorder := &statusRecorder{ResponseWriter: response}
		defer func() {
			panicValue := recover()
			status := recorder.status
			if status == 0 {
				status = http.StatusOK
			}
			if panicValue != nil && status < http.StatusInternalServerError {
				status = http.StatusInternalServerError
			}
			duration := time.Since(started)
			if metrics != nil {
				metrics.HTTPRequestFinished(request.Method, request.Pattern, status, duration)
			}
			logger.Info("http request",
				"service", serviceName,
				"version", version,
				"requestId", requestIDFromContext(request.Context()),
				"method", request.Method,
				"path", request.URL.Path,
				"status", status,
				"bytes", recorder.bytes,
				"durationMs", duration.Milliseconds(),
			)
			if panicValue != nil {
				panic(panicValue)
			}
		}()
		next.ServeHTTP(recorder, request)
	})
}

func requestIDFromContext(ctx context.Context) string {
	value, _ := ctx.Value(requestContextKey{}).(string)
	return value
}

func newRequestID() string {
	buffer := make([]byte, 12)
	if _, err := rand.Read(buffer); err == nil {
		return "req_" + hex.EncodeToString(buffer)
	}
	return "req_" + strconv.FormatInt(time.Now().UTC().UnixNano(), 36)
}
