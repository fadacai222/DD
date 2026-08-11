package media

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestS3StorePresignPutUsesOpaquePathAndShortExpiry(t *testing.T) {
	now := time.Date(2026, 8, 8, 5, 0, 0, 0, time.UTC)
	store, err := NewS3Store(S3Config{
		Endpoint:  "http://127.0.0.1:19000",
		Bucket:    "dd-media",
		Region:    "us-east-1",
		AccessKey: "test-access",
		SecretKey: "test-secret-which-is-not-production",
		Now:       func() time.Time { return now },
	})
	if err != nil {
		t.Fatalf("NewS3Store() error = %v", err)
	}

	sha256Hex := strings.Repeat("a", 64)
	signed, headers, expiresAt, err := store.PresignPut("chat-image/2026/08/opaque-key", "image/jpeg", sha256Hex, 10*time.Minute)
	if err != nil {
		t.Fatalf("PresignPut() error = %v", err)
	}
	parsed, err := url.Parse(signed)
	if err != nil {
		t.Fatalf("parse signed URL: %v", err)
	}
	if parsed.Path != "/dd-media/chat-image/2026/08/opaque-key" {
		t.Fatalf("signed path = %q", parsed.Path)
	}
	query := parsed.Query()
	for _, key := range []string{"X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Expires", "X-Amz-SignedHeaders", "X-Amz-Signature"} {
		if strings.TrimSpace(query.Get(key)) == "" {
			t.Fatalf("missing %s in %s", key, signed)
		}
	}
	if got := query.Get("X-Amz-Expires"); got != "600" {
		t.Fatalf("X-Amz-Expires = %q", got)
	}
	if headers["Content-Type"] != "image/jpeg" {
		t.Fatalf("required Content-Type = %q", headers["Content-Type"])
	}
	if strings.TrimSpace(headers["x-amz-checksum-sha256"]) == "" {
		t.Fatal("required checksum header is missing")
	}
	if got := headers["x-amz-meta-dd-sha256"]; got != sha256Hex {
		t.Fatalf("required checksum metadata = %q", got)
	}
	if got := query.Get("X-Amz-SignedHeaders"); got != "content-type;host;x-amz-checksum-sha256;x-amz-meta-dd-sha256" {
		t.Fatalf("X-Amz-SignedHeaders = %q", got)
	}
	if !expiresAt.Equal(now.Add(10 * time.Minute)) {
		t.Fatalf("expiresAt = %s", expiresAt)
	}
}

func TestS3StorePutUploadsServerGeneratedPrivateObject(t *testing.T) {
	payload := []byte("private data export payload")
	var received []byte
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPut {
			t.Errorf("method=%s", request.Method)
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if request.URL.Path != "/dd-media/data-exports/u12.json.gz" {
			t.Errorf("path=%s", request.URL.Path)
		}
		if request.Header.Get("Content-Type") != "application/gzip" {
			t.Errorf("content-type=%q", request.Header.Get("Content-Type"))
		}
		if strings.TrimSpace(request.Header.Get("x-amz-checksum-sha256")) == "" || strings.TrimSpace(request.Header.Get("x-amz-meta-dd-sha256")) == "" {
			t.Error("signed checksum headers are missing")
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("read body: %v", err)
			response.WriteHeader(http.StatusInternalServerError)
			return
		}
		received = body
		response.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	store, err := NewS3Store(S3Config{
		Endpoint: server.URL, Bucket: "dd-media", Region: "us-east-1",
		AccessKey: "test-access", SecretKey: "test-secret-which-is-not-production",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), "data-exports/u12.json.gz", "application/gzip", payload); err != nil {
		t.Fatalf("Put() error=%v", err)
	}
	if string(received) != string(payload) {
		t.Fatalf("received=%q", string(received))
	}
}

func TestS3StoreRejectsUnsafeEndpoint(t *testing.T) {
	_, err := NewS3Store(S3Config{
		Endpoint:  "ftp://storage.example.com",
		Bucket:    "dd-media",
		AccessKey: "a",
		SecretKey: "b",
	})
	if err == nil {
		t.Fatal("expected invalid endpoint error")
	}
}
