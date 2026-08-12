package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestRenderPreviewHonorsPrivacyModes(t *testing.T) {
	content := []byte(`{"text":"今晚十点见"}`)
	title, body := renderPreview(PreviewFull, "Alice", "TEXT", content)
	if title != "Alice" || body != "今晚十点见" {
		t.Fatalf("full preview=(%q,%q)", title, body)
	}
	title, body = renderPreview(PreviewSenderOnly, "Alice", "TEXT", content)
	if title != "Alice" || body != "你收到了一条新消息" {
		t.Fatalf("sender-only preview=(%q,%q)", title, body)
	}
	title, body = renderPreview(PreviewHidden, "Alice", "TEXT", content)
	if title != "DD" || body != "你收到了一条新消息" {
		t.Fatalf("hidden preview=(%q,%q)", title, body)
	}
}

func TestApplyPreviewPrivacyStripsIdentityAcrossEventTypes(t *testing.T) {
	delivery := Delivery{
		Title: "Alice",
		Body:  "正在邀请你视频通话",
		Data: map[string]string{
			"senderUserId":      "user-a",
			"senderName":        "Alice",
			"avatarUrl":         "https://example.test/avatar",
			"conversationTitle": "Secret Group",
			"conversationId":    "conversation-1",
		},
	}
	applyPreviewPrivacy(&delivery, PreviewHidden)
	if delivery.Title != "DD" || delivery.Body != "你收到了一条新消息" {
		t.Fatalf("hidden delivery=(%q,%q)", delivery.Title, delivery.Body)
	}
	for _, key := range []string{"senderUserId", "senderName", "avatarUrl", "conversationTitle"} {
		if _, ok := delivery.Data[key]; ok {
			t.Fatalf("hidden delivery leaked %s in data=%#v", key, delivery.Data)
		}
	}
	if delivery.Data["conversationId"] != "conversation-1" {
		t.Fatalf("hidden delivery lost safe routing identity=%#v", delivery.Data)
	}
}

func TestRenderGroupPreviewHonorsPrivacyModes(t *testing.T) {
	content := []byte(`{"text":"今晚十点见"}`)
	title, body := renderGroupPreview(PreviewFull, "项目群", "Alice", "TEXT", content)
	if title != "项目群" || body != "Alice: 今晚十点见" {
		t.Fatalf("full group preview=(%q,%q)", title, body)
	}
	title, body = renderGroupPreview(PreviewSenderOnly, "项目群", "Alice", "TEXT", content)
	if title != "项目群" || body != "Alice 发来一条新消息" {
		t.Fatalf("sender-only group preview=(%q,%q)", title, body)
	}
	title, body = renderGroupPreview(PreviewHidden, "Secret Group", "Secret Sender", "TEXT", content)
	if title != "DD" || body != "你收到了一条新消息" {
		t.Fatalf("hidden group preview leaked identity=(%q,%q)", title, body)
	}
}

func TestMessageTypeLabelNeverLeaksProtocolTags(t *testing.T) {
	tests := map[string]string{
		"IMAGE":        "图片",
		"GIF":          "GIF",
		"VIDEO":        "视频",
		"VOICE":        "语音消息",
		"FILE":         "文件",
		"STICKER":      "贴纸",
		"STICKER_PACK": "表情包",
		"SYSTEM":       "系统消息",
	}
	for messageType, want := range tests {
		if got := messageTypeLabel(messageType); got != want {
			t.Fatalf("messageTypeLabel(%q)=%q want %q", messageType, got, want)
		}
	}
	if got := messageTypeLabel("SOMETHING_NEW"); got != "你收到了一条新消息" {
		t.Fatalf("unknown messageType label=%q", got)
	}
}

func TestUnifiedPushProviderHandlesSuccessRetryAndGone(t *testing.T) {
	status := http.StatusCreated
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost {
			t.Fatalf("method=%s", request.Method)
		}
		if request.Header.Get("Urgency") != "high" {
			t.Fatalf("urgency=%q", request.Header.Get("Urgency"))
		}
		response.WriteHeader(status)
	}))
	defer server.Close()
	provider := NewUnifiedPushProvider(UnifiedPushConfig{})
	delivery := Delivery{Endpoint: server.URL, Title: "DD", Body: "test", HighPriority: true}
	if _, err := provider.Send(context.Background(), delivery); err != nil {
		t.Fatalf("success send: %v", err)
	}
	status = http.StatusTooManyRequests
	if _, err := provider.Send(context.Background(), delivery); !errorsIs(err, ErrRetryable) {
		t.Fatalf("429 err=%v want retryable", err)
	}
	status = http.StatusGone
	result, err := provider.Send(context.Background(), delivery)
	if err == nil || !result.InvalidToken {
		t.Fatalf("gone result=%+v err=%v", result, err)
	}
}

func TestFCMProviderUsesOAuthAndHTTPV1(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	credential, _ := json.Marshal(map[string]string{
		"project_id":   "dd-test",
		"client_email": "push@dd-test.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded})),
		"token_uri":    "https://oauth.test/token",
	})
	var oauthCalls, sendCalls int
	var sentMessage map[string]any
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Host == "oauth.test" {
			oauthCalls++
			body := io.NopCloser(strings.NewReader(`{"access_token":"access-1","expires_in":3600}`))
			return &http.Response{StatusCode: 200, Body: body, Header: make(http.Header)}, nil
		}
		if request.URL.Host != "fcm.googleapis.com" || request.URL.Path != "/v1/projects/dd-test/messages:send" {
			t.Fatalf("unexpected FCM URL %s", request.URL)
		}
		sendCalls++
		if request.Header.Get("Authorization") != "Bearer access-1" {
			t.Fatalf("authorization=%q", request.Header.Get("Authorization"))
		}
		requestBody, readErr := io.ReadAll(request.Body)
		if readErr != nil {
			t.Fatal(readErr)
		}
		var envelope map[string]any
		if err := json.Unmarshal(requestBody, &envelope); err != nil {
			t.Fatalf("decode FCM request: %v body=%s", err, requestBody)
		}
		sentMessage, _ = envelope["message"].(map[string]any)
		body := io.NopCloser(strings.NewReader(`{"name":"projects/dd-test/messages/1"}`))
		return &http.Response{StatusCode: 200, Body: body, Header: make(http.Header)}, nil
	})}
	provider, err := NewFCMProvider(FCMConfig{ServiceAccountJSON: string(credential), HTTPClient: client})
	if err != nil {
		t.Fatal(err)
	}
	delivery := Delivery{
		Endpoint: "device-token", Title: "Alice", Body: "hello",
		ConversationID: "conversation-1", Badge: 42,
		Data: map[string]string{"eventType": "MESSAGE_CREATED", "recipientUserId": "user-a"},
	}
	for range 2 {
		if _, err := provider.Send(context.Background(), delivery); err != nil {
			t.Fatal(err)
		}
	}
	if oauthCalls != 1 || sendCalls != 2 {
		t.Fatalf("oauthCalls=%d sendCalls=%d", oauthCalls, sendCalls)
	}
	if _, ok := sentMessage["notification"]; ok {
		t.Fatalf("Android FCM payload must be data-driven so DD can render MessagingStyle/avatar itself: %#v", sentMessage)
	}
	data, _ := sentMessage["data"].(map[string]any)
	if data["title"] != "Alice" || data["body"] != "hello" {
		t.Fatalf("data title/body=%#v", data)
	}
	android, _ := sentMessage["android"].(map[string]any)
	if android["priority"] != "HIGH" {
		t.Fatalf("android priority=%#v want HIGH for user-visible IM push", android["priority"])
	}
	if _, ok := android["notification"]; ok {
		t.Fatalf("android.notification would make FCM auto-render instead of DD: %#v", android)
	}
	apns, _ := sentMessage["apns"].(map[string]any)
	payload, _ := apns["payload"].(map[string]any)
	aps, _ := payload["aps"].(map[string]any)
	alert, _ := aps["alert"].(map[string]any)
	if alert["title"] != "Alice" || alert["body"] != "hello" {
		t.Fatalf("APNS alert=%#v", alert)
	}
	if aps["badge"] != float64(42) || aps["thread-id"] != "conversation-1" {
		t.Fatalf("FCM APNS badge/thread=%#v", aps)
	}

	delivery.Title = ""
	delivery.Body = ""
	delivery.Badge = 43
	delivery.BadgeOnly = true
	if _, err := provider.Send(context.Background(), delivery); err != nil {
		t.Fatalf("badge-only send: %v", err)
	}
	apns, _ = sentMessage["apns"].(map[string]any)
	payload, _ = apns["payload"].(map[string]any)
	aps, _ = payload["aps"].(map[string]any)
	if aps["badge"] != float64(43) || aps["alert"] != nil || aps["sound"] != nil {
		t.Fatalf("FCM APNS badge-only payload must stay silent: %#v", aps)
	}
	headers, _ := apns["headers"].(map[string]any)
	if headers["apns-priority"] != "5" {
		t.Fatalf("FCM APNS badge-only priority=%#v", headers)
	}
}

func TestAPNSProviderUsesTokenHeadersAndInvalidatesGoneDevice(t *testing.T) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded}))
	status := http.StatusOK
	var sentPayload map[string]any
	var sentPriority string
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/3/device/apns-token" {
			t.Fatalf("path=%s", request.URL.Path)
		}
		if !strings.HasPrefix(request.Header.Get("authorization"), "bearer ") {
			t.Fatalf("authorization missing")
		}
		if request.Header.Get("apns-topic") != "org.openimx.client" || request.Header.Get("apns-push-type") != "alert" {
			t.Fatalf("apns headers=%v", request.Header)
		}
		sentPriority = request.Header.Get("apns-priority")
		requestBody, readErr := io.ReadAll(request.Body)
		if readErr != nil {
			t.Fatal(readErr)
		}
		if err := json.Unmarshal(requestBody, &sentPayload); err != nil {
			t.Fatalf("decode APNS payload: %v body=%s", err, requestBody)
		}
		body := ""
		if status == http.StatusGone {
			body = `{"reason":"Unregistered"}`
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{"Apns-Id": []string{"id-1"}}}, nil
	})}
	provider, err := NewAPNSProvider(APNSConfig{
		KeyID: "KEY123", TeamID: "TEAM123", BundleID: "org.openimx.client", PrivateKeyPEM: keyPEM, HTTPClient: client,
		Now: func() time.Time { return time.Unix(1_800_000_000, 0).UTC() },
	})
	if err != nil {
		t.Fatal(err)
	}
	delivery := Delivery{
		Endpoint: "apns-token", Environment: "PRODUCTION", Title: "DD", Body: "hello",
		ConversationID: "conversation-2", HighPriority: true, Badge: 100,
		Data: map[string]string{"recipientUserId": "user-a"},
	}
	if result, err := provider.Send(context.Background(), delivery); err != nil || result.MessageID != "id-1" {
		t.Fatalf("success result=%+v err=%v", result, err)
	}
	aps, _ := sentPayload["aps"].(map[string]any)
	dd, _ := sentPayload["dd"].(map[string]any)
	if aps["badge"] != float64(100) || aps["thread-id"] != "conversation-2" {
		t.Fatalf("APNS badge/thread=%#v", aps)
	}
	if dd["recipientUserId"] != "user-a" {
		t.Fatalf("APNS DD payload lost account identity=%#v", dd)
	}

	delivery.Title = ""
	delivery.Body = ""
	delivery.Badge = 101
	delivery.BadgeOnly = true
	if _, err := provider.Send(context.Background(), delivery); err != nil {
		t.Fatalf("APNS badge-only send: %v", err)
	}
	aps, _ = sentPayload["aps"].(map[string]any)
	if aps["badge"] != float64(101) || aps["alert"] != nil || aps["sound"] != nil || sentPriority != "5" {
		t.Fatalf("APNS badge-only must stay silent priority=%q aps=%#v", sentPriority, aps)
	}

	status = http.StatusGone
	result, err := provider.Send(context.Background(), delivery)
	if err == nil || !result.InvalidToken {
		t.Fatalf("gone result=%+v err=%v", result, err)
	}
}

func errorsIs(err, target error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), target.Error())
}
