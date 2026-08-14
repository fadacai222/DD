package httpapi

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAdminWebServesSPAUnderAdminPrefix(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "index.html"), []byte(`<html><body>DD Admin</body></html>`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "assets", "app.js"), []byte(`console.log("dd")`), 0o644); err != nil {
		t.Fatal(err)
	}
	handler := NewHandler(Config{AdminWebRoot: root})

	login := httptest.NewRequest(http.MethodGet, "/admin/login", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, login)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "DD Admin") {
		t.Fatalf("spa status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("missing admin CSP: %q", response.Header().Get("Content-Security-Policy"))
	}

	asset := httptest.NewRequest(http.MethodGet, "/admin/assets/app.js", nil)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, asset)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "console.log") {
		t.Fatalf("asset status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Header().Get("Cache-Control"), "immutable") {
		t.Fatalf("asset cache=%q", response.Header().Get("Cache-Control"))
	}
}

func TestAdminWebRootRedirectAndMissingAsset(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "index.html"), []byte(`DD Admin`), 0o644); err != nil {
		t.Fatal(err)
	}
	handler := NewHandler(Config{AdminWebRoot: root})

	request := httptest.NewRequest(http.MethodGet, "/admin", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusPermanentRedirect || response.Header().Get("Location") != "/admin/" {
		t.Fatalf("redirect status=%d location=%q", response.Code, response.Header().Get("Location"))
	}

	request = httptest.NewRequest(http.MethodGet, "/admin/assets/missing.js", nil)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("missing asset status=%d body=%s", response.Code, response.Body.String())
	}
}
