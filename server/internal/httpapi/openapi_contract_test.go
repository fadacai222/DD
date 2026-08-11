package httpapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestOpenAPIIncludesMessageEditingAndVideoContracts(t *testing.T) {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	specPath := filepath.Join(filepath.Dir(currentFile), "..", "..", "openapi", "openapi.json")
	raw, err := os.ReadFile(specPath)
	if err != nil {
		t.Fatalf("read OpenAPI spec: %v", err)
	}
	var spec map[string]any
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatalf("parse OpenAPI spec: %v", err)
	}

	paths := mustMap(t, spec["paths"], "paths")
	messagePath := mustMap(t, paths["/api/v1/messages/{messageId}"], "message path")
	if _, ok := messagePath["patch"]; !ok {
		t.Fatal("OpenAPI message path must expose PATCH for message editing")
	}
	mentionSuggestions := mustMap(t, paths["/api/v1/users/mention-suggestions"], "mention suggestions path")
	if _, ok := mentionSuggestions["get"]; !ok {
		t.Fatal("OpenAPI must expose authenticated mention suggestions")
	}
	stableUser := mustMap(t, paths["/api/v1/users/{userId}"], "stable user path")
	if _, ok := stableUser["get"]; !ok {
		t.Fatal("OpenAPI must expose stable user-id profile lookup")
	}
	customStickers := mustMap(t, paths["/api/v1/stickers/custom"], "custom stickers path")
	for _, method := range []string{"get", "post", "delete"} {
		if _, ok := customStickers[method]; !ok {
			t.Fatalf("OpenAPI custom sticker path must expose %s", method)
		}
	}
	telegramImport := mustMap(t, paths["/api/v1/stickers/packs/telegram"], "telegram sticker import path")
	if _, ok := telegramImport["post"]; !ok {
		t.Fatal("OpenAPI must expose server-relayed Telegram sticker import")
	}
	momentsPath := mustMap(t, paths["/api/v1/moments"], "moments path")
	momentsGet := mustMap(t, momentsPath["get"], "moments get")
	momentParameters, ok := momentsGet["parameters"].([]any)
	if !ok {
		t.Fatal("OpenAPI moments GET parameters are missing")
	}
	hasAuthorFilter := false
	for _, rawParameter := range momentParameters {
		parameter, ok := rawParameter.(map[string]any)
		if ok && parameter["name"] == "authorId" {
			hasAuthorFilter = true
			break
		}
	}
	if !hasAuthorFilter {
		t.Fatal("OpenAPI moments GET must expose authorId filter")
	}

	components := mustMap(t, spec["components"], "components")
	schemas := mustMap(t, components["schemas"], "components.schemas")
	message := mustMap(t, schemas["Message"], "Message")
	messageProperties := mustMap(t, message["properties"], "Message.properties")
	assertEnumContains(t, mustMap(t, messageProperties["type"], "Message.type"), "VIDEO")
	if _, ok := messageProperties["editedAt"]; !ok {
		t.Fatal("OpenAPI Message must include editedAt")
	}
	if _, ok := messageProperties["editVersion"]; !ok {
		t.Fatal("OpenAPI Message must include editVersion")
	}

	content := mustMap(t, schemas["MessageContent"], "MessageContent")
	contentProperties := mustMap(t, content["properties"], "MessageContent.properties")
	if _, ok := contentProperties["posterMediaId"]; !ok {
		t.Fatal("OpenAPI MessageContent must include posterMediaId for VIDEO")
	}
	entities := mustMap(t, contentProperties["entities"], "MessageContent.entities")
	if entities["readOnly"] != true {
		t.Fatal("OpenAPI MessageContent.entities must be server-authoritative/readOnly")
	}
	messageEntity := mustMap(t, schemas["MessageEntity"], "MessageEntity")
	entityProperties := mustMap(t, messageEntity["properties"], "MessageEntity.properties")
	for _, property := range []string{"type", "offset", "length", "userId", "handle"} {
		if _, ok := entityProperties[property]; !ok {
			t.Fatalf("OpenAPI MessageEntity must include %s", property)
		}
	}
	mentionList := mustMap(t, schemas["MentionSuggestionListData"], "MentionSuggestionListData")
	mentionListProperties := mustMap(t, mentionList["properties"], "MentionSuggestionListData.properties")
	mentionItems := mustMap(t, mentionListProperties["items"], "MentionSuggestionListData.items")
	if mentionItems["maxItems"] != float64(8) {
		t.Fatalf("mention suggestion maxItems=%v want 8", mentionItems["maxItems"])
	}

	send := mustMap(t, schemas["SendMessageRequest"], "SendMessageRequest")
	sendProperties := mustMap(t, send["properties"], "SendMessageRequest.properties")
	assertEnumContains(t, mustMap(t, sendProperties["type"], "SendMessageRequest.type"), "VIDEO")

	edit := mustMap(t, schemas["EditMessageRequest"], "EditMessageRequest")
	editProperties := mustMap(t, edit["properties"], "EditMessageRequest.properties")
	if _, ok := editProperties["expectedEditVersion"]; !ok {
		t.Fatal("OpenAPI EditMessageRequest must include expectedEditVersion")
	}

	createMedia := mustMap(t, schemas["CreateMediaUploadRequest"], "CreateMediaUploadRequest")
	createMediaProperties := mustMap(t, createMedia["properties"], "CreateMediaUploadRequest.properties")
	assertEnumContains(t, mustMap(t, createMediaProperties["purpose"], "CreateMediaUploadRequest.purpose"), "CHAT_VIDEO")

	mediaObject := mustMap(t, schemas["MediaObject"], "MediaObject")
	mediaObjectProperties := mustMap(t, mediaObject["properties"], "MediaObject.properties")
	assertEnumContains(t, mustMap(t, mediaObjectProperties["purpose"], "MediaObject.purpose"), "CHAT_VIDEO")

	customSticker := mustMap(t, schemas["CustomSticker"], "CustomSticker")
	customStickerProperties := mustMap(t, customSticker["properties"], "CustomSticker.properties")
	for _, property := range []string{"id", "mediaId", "mimeType", "width", "height", "sizeBytes", "sortOrder", "createdAt"} {
		if _, ok := customStickerProperties[property]; !ok {
			t.Fatalf("OpenAPI CustomSticker must include %s", property)
		}
	}
	pack := mustMap(t, schemas["StickerPack"], "StickerPack")
	packProperties := mustMap(t, pack["properties"], "StickerPack.properties")
	packItems := mustMap(t, packProperties["items"], "StickerPack.items")
	if packItems["maxItems"] != float64(120) {
		t.Fatalf("sticker pack maxItems=%v want 120", packItems["maxItems"])
	}
	importRequest := mustMap(t, schemas["ImportTelegramStickerPackRequest"], "ImportTelegramStickerPackRequest")
	importProperties := mustMap(t, importRequest["properties"], "ImportTelegramStickerPackRequest.properties")
	setName := mustMap(t, importProperties["setName"], "ImportTelegramStickerPackRequest.setName")
	if setName["pattern"] != "^[A-Za-z0-9_]{1,64}$" {
		t.Fatalf("Telegram setName pattern=%v", setName["pattern"])
	}
}

func TestOpenAPIFormalRuntimeSurface(t *testing.T) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	specPath := filepath.Join(filepath.Dir(currentFile), "..", "..", "openapi", "openapi.json")
	raw, err := os.ReadFile(specPath)
	if err != nil {
		t.Fatalf("read OpenAPI spec: %v", err)
	}
	var spec map[string]any
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatalf("parse OpenAPI spec: %v", err)
	}
	paths := mustMap(t, spec["paths"], "paths")

	// This is the canonical formal HTTP surface registered by NewHandler. The
	// legacy /health,/live,/ready,/version aliases, /ws, /api/v1/realtime
	// WebSocket upgrade, and experimental /api/calls routes are intentionally
	// excluded from the formal OpenAPI v1 contract.
	expected := map[string][]string{
		"/.well-known/openimx/client":                                {"get"},
		"/api/v1/instance":                                           {"get"},
		"/api/v1/auth/register/email/send-code":                      {"post"},
		"/api/v1/auth/register":                                      {"post"},
		"/api/v1/auth/login":                                         {"post"},
		"/api/v1/auth/token/refresh":                                 {"post"},
		"/api/v1/auth/password/reset/send-code":                      {"post"},
		"/api/v1/auth/password/reset":                                {"post"},
		"/api/v1/auth/logout-all":                                    {"post"},
		"/api/v1/me":                                                 {"get", "patch"},
		"/api/v1/me/email/send-code":                                 {"post"},
		"/api/v1/me/email":                                           {"patch"},
		"/api/v1/me/avatar":                                          {"put", "delete"},
		"/api/v1/avatars/{userId}":                                   {"get"},
		"/api/v1/devices":                                            {"get"},
		"/api/v1/devices/revoked":                                    {"delete"},
		"/api/v1/devices/{deviceId}":                                 {"delete"},
		"/api/v1/users/by-handle/{handle}":                           {"get"},
		"/api/v1/users/mention-suggestions":                          {"get"},
		"/api/v1/users/{userId}":                                     {"get"},
		"/api/v1/contact-requests":                                   {"get", "post"},
		"/api/v1/contact-requests/{requestId}/accept":                {"post"},
		"/api/v1/contact-requests/{requestId}/reject":                {"post"},
		"/api/v1/contact-requests/{requestId}":                       {"delete"},
		"/api/v1/contacts":                                           {"get"},
		"/api/v1/contacts/{userId}":                                  {"put", "patch", "delete"},
		"/api/v1/blocks":                                             {"get", "post"},
		"/api/v1/blocks/{userId}":                                    {"delete"},
		"/api/v1/groups":                                             {"post"},
		"/api/v1/groups/{groupId}":                                   {"get", "patch", "delete"},
		"/api/v1/groups/{groupId}/calls":                             {"post"},
		"/api/v1/groups/{groupId}/calls/active":                      {"get"},
		"/api/v1/groups/{groupId}/calls/{callId}/join":               {"post"},
		"/api/v1/groups/{groupId}/calls/{callId}/leave":              {"post"},
		"/api/v1/groups/{groupId}/members":                           {"get", "post"},
		"/api/v1/groups/{groupId}/members/{userId}":                  {"patch", "delete"},
		"/api/v1/groups/{groupId}/leave":                             {"post"},
		"/api/v1/groups/{groupId}/transfer":                          {"post"},
		"/api/v1/groups/{groupId}/join-requests":                     {"get", "post"},
		"/api/v1/groups/{groupId}/join-requests/{requestId}/approve": {"post"},
		"/api/v1/groups/{groupId}/join-requests/{requestId}/reject":  {"post"},
		"/api/v1/moments":                                            {"get", "post"},
		"/api/v1/moments/{momentId}":                                 {"get", "delete"},
		"/api/v1/moments/{momentId}/like":                            {"put", "delete"},
		"/api/v1/moments/{momentId}/comments":                        {"post"},
		"/api/v1/moments/{momentId}/comments/{commentId}":            {"delete"},
		"/api/v1/moments/profile/{userId}":                           {"get", "patch"},
		"/api/v1/moment-preferences":                                 {"get"},
		"/api/v1/moment-preferences/{userId}":                        {"patch"},
		"/api/v1/qr/me":                                              {"get"},
		"/api/v1/group-qr-invites":                                   {"post"},
		"/api/v1/group-qr-invites/{inviteId}":                        {"delete"},
		"/api/v1/group-qr/redeem":                                    {"post"},
		"/api/v1/qr-login":                                           {"post"},
		"/api/v1/qr-login/status":                                    {"post"},
		"/api/v1/qr-login/scan":                                      {"post"},
		"/api/v1/qr-login/confirm":                                   {"post"},
		"/api/v1/qr-login/consume":                                   {"post"},
		"/api/v1/calls":                                              {"post"},
		"/api/v1/calls/active":                                       {"get"},
		"/api/v1/calls/{callId}/actions":                             {"post"},
		"/api/v1/calls/{callId}/token":                               {"post"},
		"/api/v1/conversations":                                      {"get"},
		"/api/v1/conversations/direct":                               {"post"},
		"/api/v1/conversations/{conversationId}":                     {"get", "delete"},
		"/api/v1/conversations/{conversationId}/messages":            {"get", "post"},
		"/api/v1/conversations/{conversationId}/read":                {"post"},
		"/api/v1/conversations/{conversationId}/preferences":         {"patch"},
		"/api/v1/conversations/{conversationId}/pinned-messages":     {"get"},
		"/api/v1/saved-messages/conversation":                        {"put"},
		"/api/v1/saved-messages":                                     {"get"},
		"/api/v1/messages/search":                                    {"get"},
		"/api/v1/messages/{messageId}":                               {"get", "patch"},
		"/api/v1/messages/{messageId}/recall":                        {"post"},
		"/api/v1/messages/{messageId}/local":                         {"delete"},
		"/api/v1/messages/{messageId}/save":                          {"put", "delete"},
		"/api/v1/messages/{messageId}/pin":                           {"put", "delete"},
		"/api/v1/messages/{messageId}/forward":                       {"post"},
		"/api/v1/sync":                                               {"get"},
		"/api/v1/media/uploads":                                      {"post"},
		"/api/v1/media/uploads/{uploadId}/complete":                  {"post"},
		"/api/v1/media/{mediaId}":                                    {"get"},
		"/api/v1/media/{mediaId}/download-url":                       {"post"},
		"/api/v1/stickers/custom":                                    {"get", "post", "delete"},
		"/api/v1/stickers/custom/order":                              {"put"},
		"/api/v1/stickers/packs":                                     {"get"},
		"/api/v1/stickers/packs/telegram":                            {"post"},
		"/api/v1/stickers/packs/{packId}":                            {"delete"},
		"/api/v1/system/live":                                        {"get"},
		"/api/v1/system/ready":                                       {"get"},
		"/api/v1/system/version":                                     {"get"},
	}

	if len(paths) != len(expected) {
		t.Fatalf("OpenAPI formal path count=%d want %d", len(paths), len(expected))
	}
	for path, methods := range expected {
		operationSet := mustMap(t, paths[path], path)
		for _, method := range methods {
			if _, ok := operationSet[method]; !ok {
				t.Fatalf("OpenAPI %s must expose %s", path, method)
			}
		}
		for key := range operationSet {
			switch key {
			case "parameters", "summary", "description", "$ref":
				continue
			case "get", "post", "put", "patch", "delete", "head", "options", "trace":
				if !containsString(methods, key) {
					t.Fatalf("OpenAPI %s exposes unexpected method %s", path, key)
				}
			}
		}
	}
}

func containsString(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func mustMap(t *testing.T, value any, label string) map[string]any {
	t.Helper()
	mapped, ok := value.(map[string]any)
	if !ok {
		t.Fatalf("%s is missing or malformed", label)
	}
	return mapped
}

func assertEnumContains(t *testing.T, schema map[string]any, expected string) {
	t.Helper()
	values, ok := schema["enum"].([]any)
	if !ok {
		t.Fatalf("enum for %s is missing or malformed", expected)
	}
	for _, value := range values {
		if value == expected {
			return
		}
	}
	t.Fatalf("enum does not contain %s: %#v", expected, values)
}
