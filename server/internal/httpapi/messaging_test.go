package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/messaging"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/google/uuid"
)

type fakeMessagingService struct {
	sendInput        messaging.SendMessageInput
	sendPrincipal    account.Principal
	sendConversation uuid.UUID
	sendErr          error
	editInput        messaging.EditMessageInput
	editMessageID    uuid.UUID
	editErr          error
}

func (f *fakeMessagingService) EnsureDirectConversation(_ context.Context, _ account.Principal, target uuid.UUID) (messaging.Conversation, error) {
	return messaging.Conversation{ID: uuid.NewString(), Type: "DIRECT", Peer: &messaging.UserPreview{ID: target.String()}}, nil
}
func (f *fakeMessagingService) EnsureSavedConversation(_ context.Context, principal account.Principal) (messaging.Conversation, error) {
	return messaging.Conversation{ID: uuid.NewString(), Type: "SELF", Peer: &messaging.UserPreview{ID: principal.UserID.String()}, CanWrite: true}, nil
}
func (f *fakeMessagingService) ListConversations(context.Context, account.Principal, int) ([]messaging.Conversation, error) {
	return []messaging.Conversation{}, nil
}
func (f *fakeMessagingService) GetConversation(_ context.Context, _ account.Principal, id uuid.UUID) (messaging.Conversation, error) {
	return messaging.Conversation{ID: id.String(), Type: "DIRECT"}, nil
}
func (f *fakeMessagingService) UpdatePreferences(_ context.Context, _ account.Principal, id uuid.UUID, _ messaging.UpdatePreferencesInput) (messaging.Conversation, error) {
	return messaging.Conversation{ID: id.String(), Type: "DIRECT"}, nil
}
func (f *fakeMessagingService) HideConversation(_ context.Context, _ account.Principal, _ uuid.UUID) error {
	return nil
}
func (f *fakeMessagingService) MarkRead(_ context.Context, _ account.Principal, id uuid.UUID, sequence int64) (messaging.MarkReadResult, []uuid.UUID, error) {
	return messaging.MarkReadResult{ConversationID: id.String(), LastReadSequence: sequence}, nil, nil
}
func (f *fakeMessagingService) SendMessage(_ context.Context, principal account.Principal, id uuid.UUID, input messaging.SendMessageInput) (messaging.SendResult, error) {
	f.sendPrincipal, f.sendConversation, f.sendInput = principal, id, input
	return messaging.SendResult{Message: messaging.Message{ID: uuid.NewString(), ConversationID: id.String(), Sequence: 1, SenderUserID: principal.UserID.String(), SenderDeviceID: principal.DeviceID.String(), ClientMessageID: input.ClientMessageID, Type: "TEXT", Content: input.Content}}, f.sendErr
}
func (f *fakeMessagingService) ListMessages(context.Context, account.Principal, uuid.UUID, int64, int) (messaging.MessagePage, error) {
	return messaging.MessagePage{Items: []messaging.Message{}}, nil
}
func (f *fakeMessagingService) GetMessage(_ context.Context, _ account.Principal, id uuid.UUID) (messaging.Message, error) {
	return messaging.Message{ID: id.String()}, nil
}
func (f *fakeMessagingService) EditMessage(_ context.Context, principal account.Principal, id uuid.UUID, input messaging.EditMessageInput) (messaging.SendResult, error) {
	f.editMessageID, f.editInput = id, input
	if f.editErr != nil {
		return messaging.SendResult{}, f.editErr
	}
	now := time.Now().UTC()
	return messaging.SendResult{
		Message: messaging.Message{
			ID: id.String(), SenderUserID: principal.UserID.String(), Type: "TEXT",
			Content: &messaging.TextContent{Text: input.Text}, EditedAt: &now, EditVersion: input.ExpectedEditVersion + 1,
		},
		NotifyUserIDs: []uuid.UUID{principal.UserID},
	}, nil
}
func (f *fakeMessagingService) RecallMessage(_ context.Context, _ account.Principal, id uuid.UUID) (messaging.SendResult, error) {
	return messaging.SendResult{Message: messaging.Message{ID: id.String()}}, nil
}
func (f *fakeMessagingService) DeleteMessageLocally(context.Context, account.Principal, uuid.UUID) error {
	return nil
}
func (f *fakeMessagingService) SaveMessage(_ context.Context, _ account.Principal, id uuid.UUID) (messaging.SavedMessage, error) {
	return messaging.SavedMessage{Message: messaging.Message{ID: id.String()}, SavedAt: time.Now().UTC()}, nil
}
func (f *fakeMessagingService) UnsaveMessage(context.Context, account.Principal, uuid.UUID) error {
	return nil
}
func (f *fakeMessagingService) ListSavedMessages(context.Context, account.Principal, int) ([]messaging.SavedMessage, error) {
	return []messaging.SavedMessage{}, nil
}
func (f *fakeMessagingService) PinMessage(_ context.Context, principal account.Principal, id uuid.UUID) (messaging.PinnedMessage, []uuid.UUID, error) {
	return messaging.PinnedMessage{Message: messaging.Message{ID: id.String()}, PinnedByUserID: principal.UserID.String(), PinnedAt: time.Now().UTC()}, []uuid.UUID{principal.UserID}, nil
}
func (f *fakeMessagingService) UnpinMessage(_ context.Context, principal account.Principal, _ uuid.UUID) ([]uuid.UUID, error) {
	return []uuid.UUID{principal.UserID}, nil
}
func (f *fakeMessagingService) ListPinnedMessages(context.Context, account.Principal, uuid.UUID, int) ([]messaging.PinnedMessage, error) {
	return []messaging.PinnedMessage{}, nil
}
func (f *fakeMessagingService) SearchMessages(context.Context, account.Principal, string, *uuid.UUID, int) ([]messaging.MessageSearchHit, error) {
	return []messaging.MessageSearchHit{}, nil
}
func (f *fakeMessagingService) ForwardMessage(_ context.Context, principal account.Principal, _ uuid.UUID, input messaging.ForwardMessageInput) (messaging.SendResult, error) {
	return messaging.SendResult{Message: messaging.Message{ID: uuid.NewString(), ConversationID: input.TargetConversationID, SenderUserID: principal.UserID.String(), ClientMessageID: input.ClientMessageID, Type: "TEXT"}}, nil
}
func (f *fakeMessagingService) Sync(_ context.Context, _ account.Principal, cursor int64, _ int) (messaging.SyncPage, error) {
	return messaging.SyncPage{Items: []messaging.SyncEvent{}, NextCursor: cursor}, nil
}
func (f *fakeMessagingService) DispatchOutbox(context.Context, int) (int, error) {
	return 0, nil
}

type stablePrincipalAuthService struct {
	fakeAuthService
	principal account.Principal
	authErr   error
}

func (f *stablePrincipalAuthService) AuthenticateAccessToken(_ context.Context, raw string) (account.Principal, error) {
	if raw == "" || f.authErr != nil {
		return account.Principal{}, f.authErr
	}
	return f.principal, nil
}

func TestMessagingEndpointsRequireAccessToken(t *testing.T) {
	handler := NewHandler(Config{MessagingService: &fakeMessagingService{}})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/conversations", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("without auth service status=%d body=%s", response.Code, response.Body.String())
	}

	handler = NewHandler(Config{AuthService: &fakeAuthService{}, MessagingService: &fakeMessagingService{}})
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("without bearer token status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestSendMessageRejectsClientSenderIdentityAndUsesPrincipal(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	auth := &stablePrincipalAuthService{principal: principal}
	messages := &fakeMessagingService{}
	handler := NewHandler(Config{AuthService: auth, MessagingService: messages})
	conversationID := uuid.New()

	forgedBody, _ := json.Marshal(map[string]any{
		"clientMessageId": "client-00000001",
		"type":            "TEXT",
		"content":         map[string]any{"text": "hello"},
		"senderUserId":    "attacker",
		"senderDeviceId":  "attacker",
	})
	forged := httptest.NewRequest(http.MethodPost, "/api/v1/conversations/"+conversationID.String()+"/messages", strings.NewReader(string(forgedBody)))
	forged.Header.Set("Authorization", "Bearer valid")
	forged.Header.Set("Content-Type", "application/json")
	forgedResponse := httptest.NewRecorder()
	handler.ServeHTTP(forgedResponse, forged)
	if forgedResponse.Code != http.StatusBadRequest {
		t.Fatalf("forged sender status=%d body=%s", forgedResponse.Code, forgedResponse.Body.String())
	}

	validBody, _ := json.Marshal(map[string]any{
		"clientMessageId": "client-00000002",
		"type":            "TEXT",
		"content":         map[string]any{"text": "hello"},
	})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/conversations/"+conversationID.String()+"/messages", strings.NewReader(string(validBody)))
	request.Header.Set("Authorization", "Bearer valid")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusCreated {
		t.Fatalf("valid send status=%d body=%s", response.Code, response.Body.String())
	}
	if messages.sendPrincipal != principal || messages.sendConversation != conversationID || messages.sendInput.ClientMessageID != "client-00000002" {
		t.Fatalf("trusted principal/message mismatch: principal=%#v conversation=%s input=%#v", messages.sendPrincipal, messages.sendConversation, messages.sendInput)
	}
}

func TestEditMessagePATCHAndConflictError(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	auth := &stablePrincipalAuthService{principal: principal}
	messages := &fakeMessagingService{}
	handler := NewHandler(Config{AuthService: auth, MessagingService: messages})
	messageID := uuid.New()

	body := `{"text":"updated body","expectedEditVersion":2}`
	request := httptest.NewRequest(http.MethodPatch, "/api/v1/messages/"+messageID.String(), strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer valid")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("edit status=%d body=%s", response.Code, response.Body.String())
	}
	if messages.editMessageID != messageID || messages.editInput.Text != "updated body" || messages.editInput.ExpectedEditVersion != 2 {
		t.Fatalf("edit input mismatch id=%s input=%#v", messages.editMessageID, messages.editInput)
	}

	messages.editErr = messaging.ErrEditConflict
	request = httptest.NewRequest(http.MethodPatch, "/api/v1/messages/"+messageID.String(), strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer valid")
	request.Header.Set("Content-Type", "application/json")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "MESSAGE_EDIT_CONFLICT") {
		t.Fatalf("conflict status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestWriteJSONEncodingFailureReturnsStructuredServerError(t *testing.T) {
	response := httptest.NewRecorder()
	response.Header().Set(requestIDHeader, "req-json-encode-test")
	writeJSON(response, http.StatusOK, map[string]any{
		"badTime": time.Date(10000, 1, 1, 0, 0, 0, 0, time.UTC),
	})
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status=%d body=%q", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), "RESPONSE_ENCODING_FAILED") ||
		!strings.Contains(response.Body.String(), "req-json-encode-test") {
		t.Fatalf("unexpected encoding failure body=%q", response.Body.String())
	}
}

func TestFormalRealtimeAuthenticatesAndChecksProtocolVersion(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	auth := &stablePrincipalAuthService{principal: principal}
	server := httptest.NewServer(NewHandler(Config{Version: "p4-test", AuthService: auth}))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/api/v1/realtime"

	for _, test := range []struct {
		name        string
		version     string
		wantType    string
		wantErrCode string
	}{
		{name: "authenticated", version: "1", wantType: "hello_ack"},
		{name: "version mismatch", version: "999", wantType: "error", wantErrCode: "PROTOCOL_VERSION_MISMATCH"},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			connection, _, err := websocket.Dial(ctx, wsURL, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer connection.CloseNow()
			if err := wsjson.Write(ctx, connection, map[string]any{
				"type": "hello", "requestId": "hello-1",
				"payload": map[string]any{"clientId": "p4-client", "accessToken": "valid", "protocolVersion": test.version, "lastEventId": 0},
			}); err != nil {
				t.Fatal(err)
			}
			var result struct {
				Type  string `json:"type"`
				Error *struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := wsjson.Read(ctx, connection, &result); err != nil {
				t.Fatal(err)
			}
			if result.Type != test.wantType {
				t.Fatalf("type=%s want=%s", result.Type, test.wantType)
			}
			if test.wantErrCode != "" && (result.Error == nil || result.Error.Code != test.wantErrCode) {
				t.Fatalf("error=%#v want=%s", result.Error, test.wantErrCode)
			}
		})
	}
}

func TestSyncResponseIsCursorBased(t *testing.T) {
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	auth := &stablePrincipalAuthService{principal: principal}
	handler := NewHandler(Config{AuthService: auth, MessagingService: &fakeMessagingService{}})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/sync?cursor=42&limit=200", nil)
	request.Header.Set("Authorization", "Bearer valid")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Data messaging.SyncPage `json:"data"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Data.NextCursor != 42 || body.Data.HasMore {
		t.Fatalf("sync=%#v", body.Data)
	}
}
