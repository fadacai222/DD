package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/qrcode"
	"github.com/google/uuid"
)

type fakeQRService struct {
	lastNonce string
	approved  *bool
	login     qrcode.LoginSession
	err       error
}

func (f *fakeQRService) UserPayload(userID uuid.UUID) (qrcode.Payload, error) {
	return qrcode.Payload{Type: "USER", Value: "dd://qr/v1/user?userId=" + userID.String()}, f.err
}
func (f *fakeQRService) CreateGroupInvite(_ context.Context, _ account.Principal, groupID uuid.UUID, _ qrcode.CreateGroupInviteInput) (qrcode.GroupInvite, error) {
	return qrcode.GroupInvite{ID: uuid.NewString(), GroupID: groupID.String(), Payload: "dd://qr/v1/group?nonce=test", CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour)}, f.err
}
func (f *fakeQRService) RevokeGroupInvite(_ context.Context, _ account.Principal, _ uuid.UUID) error {
	return f.err
}
func (f *fakeQRService) RedeemGroupInvite(_ context.Context, _ account.Principal, nonce string) (qrcode.GroupRedeemResult, []uuid.UUID, error) {
	f.lastNonce = nonce
	return qrcode.GroupRedeemResult{}, nil, f.err
}
func (f *fakeQRService) CreateLogin(_ context.Context, _ qrcode.CreateLoginInput) (qrcode.LoginSession, error) {
	return f.login, f.err
}
func (f *fakeQRService) PollLogin(_ context.Context, nonce string) (qrcode.LoginSession, error) {
	f.lastNonce = nonce
	return f.login, f.err
}
func (f *fakeQRService) ScanLogin(_ context.Context, _ account.Principal, nonce string) (qrcode.LoginSession, error) {
	f.lastNonce = nonce
	return f.login, f.err
}
func (f *fakeQRService) ConfirmLogin(_ context.Context, _ account.Principal, nonce string, approved bool) (qrcode.LoginSession, error) {
	f.lastNonce = nonce
	f.approved = &approved
	return f.login, f.err
}
func (f *fakeQRService) ConsumeLogin(_ context.Context, nonce string) (qrcode.ConsumeLoginResult, error) {
	f.lastNonce = nonce
	return qrcode.ConsumeLoginResult{}, f.err
}

func TestQRLoginNonceStaysInPostBody(t *testing.T) {
	fake := &fakeQRService{login: qrcode.LoginSession{Status: "PENDING", ExpiresAt: time.Now().UTC().Add(time.Minute)}}
	handler := NewHandler(Config{QRService: fake})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/qr-login/status", strings.NewReader(`{"nonce":"secret-nonce"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || fake.lastNonce != "secret-nonce" {
		t.Fatalf("status=%d nonce=%q body=%s", response.Code, fake.lastNonce, response.Body.String())
	}
	if strings.Contains(request.URL.String(), "secret-nonce") {
		t.Fatalf("secret nonce leaked into URL: %s", request.URL.String())
	}
}

func TestQRLoginScanAndConfirmRequireAuthenticatedDevice(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	fake := &fakeQRService{login: qrcode.LoginSession{Status: "SCANNED", ExpiresAt: time.Now().UTC().Add(time.Minute)}}
	handler := NewHandler(Config{AuthService: &stablePrincipalAuthService{principal: principal}, QRService: fake})

	unauthorized := httptest.NewRequest(http.MethodPost, "/api/v1/qr-login/scan", strings.NewReader(`{"nonce":"abc"}`))
	unauthorized.Header.Set("Content-Type", "application/json")
	unauthorizedResponse := httptest.NewRecorder()
	handler.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("scan without bearer status=%d body=%s", unauthorizedResponse.Code, unauthorizedResponse.Body.String())
	}

	confirm := httptest.NewRequest(http.MethodPost, "/api/v1/qr-login/confirm", strings.NewReader(`{"nonce":"abc","approved":true}`))
	confirm.Header.Set("Content-Type", "application/json")
	confirm.Header.Set("Authorization", "Bearer access")
	confirmResponse := httptest.NewRecorder()
	handler.ServeHTTP(confirmResponse, confirm)
	if confirmResponse.Code != http.StatusOK || fake.lastNonce != "abc" || fake.approved == nil || !*fake.approved {
		t.Fatalf("confirm status=%d nonce=%q approved=%v body=%s", confirmResponse.Code, fake.lastNonce, fake.approved, confirmResponse.Body.String())
	}
}

func TestQRErrorsKeepStableMachineCodes(t *testing.T) {
	for _, test := range []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{name: "expired", err: qrcode.ErrExpired, wantStatus: http.StatusGone, wantCode: "QR_EXPIRED"},
		{name: "consumed", err: qrcode.ErrConsumed, wantStatus: http.StatusGone, wantCode: "QR_CONSUMED"},
		{name: "conflict", err: qrcode.ErrConflict, wantStatus: http.StatusConflict, wantCode: "QR_STATE_CONFLICT"},
	} {
		t.Run(test.name, func(t *testing.T) {
			fake := &fakeQRService{err: test.err}
			handler := NewHandler(Config{QRService: fake})
			request := httptest.NewRequest(http.MethodPost, "/api/v1/qr-login/status", strings.NewReader(`{"nonce":"abc"}`))
			request.Header.Set("Content-Type", "application/json")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != test.wantStatus || !strings.Contains(response.Body.String(), `"code":"`+test.wantCode+`"`) {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}
