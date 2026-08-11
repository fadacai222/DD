package httpapi

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/push"
	"github.com/google/uuid"
)

func TestSignedPushAvatarAssetDoesNotRequireSessionButRejectsExpiredCapability(t *testing.T) {
	userID := uuid.MustParse("11111111-2222-3333-4444-555555555555")
	now := time.Date(2026, 8, 12, 4, 0, 0, 0, time.UTC)
	secret := "0123456789abcdef0123456789abcdef"
	handler := NewHandler(Config{
		AuthService:      &fakeAuthService{},
		PushAvatarSecret: secret,
		Now:              func() time.Time { return now },
	})

	raw := push.SignedAvatarURL("https://chat.example.com", secret, userID, now.Add(time.Hour))
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, parsed.RequestURI(), nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("valid status=%d body=%s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("Content-Type"); got != "image/png" {
		t.Fatalf("content-type=%q", got)
	}
	if response.Header().Get("Cache-Control") == "" {
		t.Fatal("push avatar asset should be cacheable for the capability lifetime")
	}

	expired := push.SignedAvatarURL("https://chat.example.com", secret, userID, now.Add(time.Second))
	expiredURL, _ := url.Parse(expired)
	now = now.Add(2 * time.Second)
	expiredRequest := httptest.NewRequest(http.MethodGet, expiredURL.RequestURI(), nil)
	expiredResponse := httptest.NewRecorder()
	handler.ServeHTTP(expiredResponse, expiredRequest)
	if expiredResponse.Code != http.StatusNotFound {
		t.Fatalf("expired status=%d body=%s", expiredResponse.Code, expiredResponse.Body.String())
	}
}
