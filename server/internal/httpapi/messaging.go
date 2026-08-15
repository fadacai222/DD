package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/messaging"
	"example.com/selfhosted-im/server/internal/protocol"
	"example.com/selfhosted-im/server/internal/transcription"
	"github.com/google/uuid"
)

type MessagingService interface {
	EnsureDirectConversation(ctx context.Context, principal account.Principal, targetUserID uuid.UUID) (messaging.Conversation, error)
	EnsureSavedConversation(ctx context.Context, principal account.Principal) (messaging.Conversation, error)
	ListConversations(ctx context.Context, principal account.Principal, limit int) ([]messaging.Conversation, error)
	GetConversation(ctx context.Context, principal account.Principal, conversationID uuid.UUID) (messaging.Conversation, error)
	UpdatePreferences(ctx context.Context, principal account.Principal, conversationID uuid.UUID, input messaging.UpdatePreferencesInput) (messaging.Conversation, error)
	HideConversation(ctx context.Context, principal account.Principal, conversationID uuid.UUID) error
	MarkRead(ctx context.Context, principal account.Principal, conversationID uuid.UUID, sequence int64) (messaging.MarkReadResult, []uuid.UUID, error)
	SendMessage(ctx context.Context, principal account.Principal, conversationID uuid.UUID, input messaging.SendMessageInput) (messaging.SendResult, error)
	ListMessages(ctx context.Context, principal account.Principal, conversationID uuid.UUID, beforeSequence int64, limit int) (messaging.MessagePage, error)
	GetMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (messaging.Message, error)
	EditMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID, input messaging.EditMessageInput) (messaging.SendResult, error)
	RecallMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (messaging.SendResult, error)
	DeleteMessageLocally(ctx context.Context, principal account.Principal, messageID uuid.UUID) error
	SaveMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (messaging.SavedMessage, error)
	UnsaveMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) error
	ListSavedMessages(ctx context.Context, principal account.Principal, limit int) ([]messaging.SavedMessage, error)
	PinMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (messaging.PinnedMessage, []uuid.UUID, error)
	UnpinMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) ([]uuid.UUID, error)
	ListPinnedMessages(ctx context.Context, principal account.Principal, conversationID uuid.UUID, limit int) ([]messaging.PinnedMessage, error)
	SearchMessages(ctx context.Context, principal account.Principal, query string, conversationID *uuid.UUID, limit int) ([]messaging.MessageSearchHit, error)
	ForwardMessage(ctx context.Context, principal account.Principal, sourceMessageID uuid.UUID, input messaging.ForwardMessageInput) (messaging.SendResult, error)
	Sync(ctx context.Context, principal account.Principal, cursor int64, limit int) (messaging.SyncPage, error)
	DispatchOutbox(ctx context.Context, limit int) (int, error)
}

func (s *server) handleConversations(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	limit, ok := parseBoundedIntQuery(response, request, "limit", 100, 1, 100)
	if !ok {
		return
	}
	items, err := s.messaging.ListConversations(request.Context(), principal, limit)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleDirectConversation(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok || !requireJSON(response, request) {
		return
	}
	var input messaging.DirectConversationInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	targetID, err := uuid.Parse(strings.TrimSpace(input.UserID))
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "userId must be a UUID")
		return
	}
	result, err := s.messaging.EnsureDirectConversation(request.Context(), principal, targetID)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleConversationByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/conversations/"), "/"), "/")
	if len(parts) < 1 || len(parts) > 2 || strings.TrimSpace(parts[0]) == "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	conversationID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "conversationId must be a UUID")
		return
	}
	if len(parts) == 1 {
		switch request.Method {
		case http.MethodGet:
			result, err := s.messaging.GetConversation(request.Context(), principal, conversationID)
			if err != nil {
				s.writeMessagingError(response, request, err)
				return
			}
			writeSuccess(response, http.StatusOK, result)
		case http.MethodDelete:
			if err := s.messaging.HideConversation(request.Context(), principal, conversationID); err != nil {
				s.writeMessagingError(response, request, err)
				return
			}
			s.publishEventAvailable([]uuid.UUID{principal.UserID}, "conversation-hidden")
			response.WriteHeader(http.StatusNoContent)
		default:
			methodNotAllowed(response, http.MethodGet, http.MethodDelete)
		}
		return
	}

	switch parts[1] {
	case "messages":
		s.handleConversationMessages(response, request, principal, conversationID)
	case "read":
		s.handleConversationRead(response, request, principal, conversationID)
	case "preferences":
		s.handleConversationPreferences(response, request, principal, conversationID)
	case "pinned-messages":
		s.handleConversationPinnedMessages(response, request, principal, conversationID)
	default:
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
	}
}

func (s *server) handleConversationMessages(response http.ResponseWriter, request *http.Request, principal account.Principal, conversationID uuid.UUID) {
	switch request.Method {
	case http.MethodGet:
		before, ok := parseBoundedInt64Query(response, request, "beforeSequence", 0, 0)
		if !ok {
			return
		}
		limit, ok := parseBoundedIntQuery(response, request, "limit", messaging.DefaultHistoryLimit, 1, messaging.MaximumHistoryLimit)
		if !ok {
			return
		}
		result, err := s.messaging.ListMessages(request.Context(), principal, conversationID, before, limit)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	case http.MethodPost:
		if !requireJSON(response, request) {
			return
		}
		var input messaging.SendMessageInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
			return
		}
		result, err := s.messaging.SendMessage(request.Context(), principal, conversationID, input)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		s.publishEventAvailable(result.NotifyUserIDs, "message")
		writeSuccess(response, http.StatusCreated, result.Message)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPost)
	}
}

func (s *server) handleConversationRead(response http.ResponseWriter, request *http.Request, principal account.Principal, conversationID uuid.UUID) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input messaging.MarkReadInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, userIDs, err := s.messaging.MarkRead(request.Context(), principal, conversationID, input.Sequence)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	s.publishEventAvailable(userIDs, "read")
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleConversationPreferences(response http.ResponseWriter, request *http.Request, principal account.Principal, conversationID uuid.UUID) {
	if request.Method != http.MethodPatch {
		methodNotAllowed(response, http.MethodPatch)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input messaging.UpdatePreferencesInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.messaging.UpdatePreferences(request.Context(), principal, conversationID, input)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	s.publishEventAvailable([]uuid.UUID{principal.UserID}, "preferences")
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleMessageByID(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/messages/"), "/"), "/")
	if len(parts) < 1 || len(parts) > 2 || strings.TrimSpace(parts[0]) == "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	messageID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "messageId must be a UUID")
		return
	}
	if len(parts) == 1 {
		switch request.Method {
		case http.MethodGet:
			result, err := s.messaging.GetMessage(request.Context(), principal, messageID)
			if err != nil {
				s.writeMessagingError(response, request, err)
				return
			}
			writeSuccess(response, http.StatusOK, result)
		case http.MethodPatch:
			if !requireJSON(response, request) {
				return
			}
			var requestBody struct {
				Text                string `json:"text"`
				ExpectedEditVersion *int   `json:"expectedEditVersion"`
			}
			if err := decodeSingleJSON(response, request, &requestBody); err != nil {
				writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
				return
			}
			if requestBody.ExpectedEditVersion == nil {
				writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "expectedEditVersion is required")
				return
			}
			input := messaging.EditMessageInput{
				Text:                requestBody.Text,
				ExpectedEditVersion: *requestBody.ExpectedEditVersion,
			}
			result, err := s.messaging.EditMessage(request.Context(), principal, messageID, input)
			if err != nil {
				s.writeMessageEditError(response, request, err)
				return
			}
			s.publishEventAvailable(result.NotifyUserIDs, "message-edited")
			writeSuccess(response, http.StatusOK, result.Message)
		default:
			methodNotAllowed(response, http.MethodGet, http.MethodPatch)
		}
		return
	}
	switch parts[1] {
	case "recall":
		if request.Method != http.MethodPost {
			methodNotAllowed(response, http.MethodPost)
			return
		}
		result, err := s.messaging.RecallMessage(request.Context(), principal, messageID)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		s.publishEventAvailable(result.NotifyUserIDs, "recall")
		writeSuccess(response, http.StatusOK, result.Message)
	case "local":
		if request.Method != http.MethodDelete {
			methodNotAllowed(response, http.MethodDelete)
			return
		}
		if err := s.messaging.DeleteMessageLocally(request.Context(), principal, messageID); err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		s.publishEventAvailable([]uuid.UUID{principal.UserID}, "local-delete")
		writeSuccess(response, http.StatusOK, map[string]any{"deleted": true})
	case "save":
		s.handleMessageSave(response, request, principal, messageID)
	case "pin":
		s.handleMessagePin(response, request, principal, messageID)
	case "forward":
		s.handleMessageForward(response, request, principal, messageID)
	case "transcription":
		s.handleMessageTranscription(response, request, principal, messageID)
	default:
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
	}
}

func (s *server) handleSavedConversation(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPut {
		methodNotAllowed(response, http.MethodPut)
		return
	}
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok {
		return
	}
	result, err := s.messaging.EnsureSavedConversation(request.Context(), principal)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	s.publishEventAvailable([]uuid.UUID{principal.UserID}, "saved-conversation")
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleSavedMessages(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	limit, ok := parseBoundedIntQuery(response, request, "limit", messaging.DefaultProductivityLimit, 1, messaging.MaximumProductivityLimit)
	if !ok {
		return
	}
	items, err := s.messaging.ListSavedMessages(request.Context(), principal, limit)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleMessageSearch(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok {
		return
	}
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	limit, ok := parseBoundedIntQuery(response, request, "limit", messaging.DefaultProductivityLimit, 1, messaging.MaximumProductivityLimit)
	if !ok {
		return
	}
	var conversationID *uuid.UUID
	if raw := strings.TrimSpace(request.URL.Query().Get("conversationId")); raw != "" {
		parsed, err := uuid.Parse(raw)
		if err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "conversationId must be a UUID")
			return
		}
		conversationID = &parsed
	}
	items, err := s.messaging.SearchMessages(request.Context(), principal, request.URL.Query().Get("q"), conversationID, limit)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleConversationPinnedMessages(response http.ResponseWriter, request *http.Request, principal account.Principal, conversationID uuid.UUID) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	limit, ok := parseBoundedIntQuery(response, request, "limit", messaging.DefaultProductivityLimit, 1, messaging.MaximumProductivityLimit)
	if !ok {
		return
	}
	items, err := s.messaging.ListPinnedMessages(request.Context(), principal, conversationID, limit)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleMessageSave(response http.ResponseWriter, request *http.Request, principal account.Principal, messageID uuid.UUID) {
	switch request.Method {
	case http.MethodPut:
		result, err := s.messaging.SaveMessage(request.Context(), principal, messageID)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		s.publishEventAvailable([]uuid.UUID{principal.UserID}, "saved-message")
		writeSuccess(response, http.StatusOK, result)
	case http.MethodDelete:
		if err := s.messaging.UnsaveMessage(request.Context(), principal, messageID); err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		s.publishEventAvailable([]uuid.UUID{principal.UserID}, "saved-message")
		writeSuccess(response, http.StatusOK, map[string]any{"saved": false})
	default:
		methodNotAllowed(response, http.MethodPut, http.MethodDelete)
	}
}

func (s *server) handleMessagePin(response http.ResponseWriter, request *http.Request, principal account.Principal, messageID uuid.UUID) {
	switch request.Method {
	case http.MethodPut:
		result, userIDs, err := s.messaging.PinMessage(request.Context(), principal, messageID)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		s.publishEventAvailable(userIDs, "pinned-message")
		writeSuccess(response, http.StatusOK, result)
	case http.MethodDelete:
		userIDs, err := s.messaging.UnpinMessage(request.Context(), principal, messageID)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		s.publishEventAvailable(userIDs, "pinned-message")
		writeSuccess(response, http.StatusOK, map[string]any{"pinned": false})
	default:
		methodNotAllowed(response, http.MethodPut, http.MethodDelete)
	}
}

func (s *server) handleMessageForward(response http.ResponseWriter, request *http.Request, principal account.Principal, messageID uuid.UUID) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input messaging.ForwardMessageInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	result, err := s.messaging.ForwardMessage(request.Context(), principal, messageID, input)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	s.publishEventAvailable(result.NotifyUserIDs, "message-forward")
	writeSuccess(response, http.StatusCreated, result.Message)
}

func (s *server) handleSync(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, ok := s.requireMessagingPrincipal(response, request)
	if !ok {
		return
	}
	cursor, ok := parseBoundedInt64Query(response, request, "cursor", 0, 0)
	if !ok {
		return
	}
	limit, ok := parseBoundedIntQuery(response, request, "limit", messaging.DefaultSyncLimit, 1, messaging.MaximumSyncLimit)
	if !ok {
		return
	}
	if _, err := s.messaging.DispatchOutbox(request.Context(), 100); err != nil {
		s.logger.Warn("sync pre-dispatch failed; worker will retry", "requestId", response.Header().Get(requestIDHeader), "error", err)
	}
	result, err := s.messaging.Sync(request.Context(), principal, cursor, limit)
	if err != nil {
		s.writeMessagingError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) requireMessagingPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.messaging == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "MESSAGING_SERVICE_UNAVAILABLE", "Messaging service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) writeMessageEditError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, messaging.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "MESSAGE_NOT_FOUND", "Message was not found")
	case errors.Is(err, messaging.ErrEditForbidden), errors.Is(err, messaging.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "MESSAGE_EDIT_FORBIDDEN", "Message cannot be edited by this user")
	case errors.Is(err, messaging.ErrEditUnsupported):
		writeAPIError(response, http.StatusBadRequest, "MESSAGE_EDIT_UNSUPPORTED", "This message type cannot be edited")
	case errors.Is(err, messaging.ErrEditConflict):
		writeAPIError(response, http.StatusConflict, "MESSAGE_EDIT_CONFLICT", "Message was edited on another device")
	case errors.Is(err, messaging.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "Message edit request is invalid")
	default:
		s.writeMessagingError(response, request, err)
	}
}

func (s *server) writeMessagingError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, messaging.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested messaging resource was not found")
	case errors.Is(err, messaging.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "MESSAGING_FORBIDDEN", "Messaging operation is not allowed")
	case errors.Is(err, messaging.ErrBlocked):
		writeAPIError(response, http.StatusForbidden, "MESSAGING_BLOCKED", "Messaging is blocked for this relationship")
	case errors.Is(err, messaging.ErrPinnedLimit):
		writeAPIError(response, http.StatusConflict, "PINNED_CONVERSATION_LIMIT", "最多只能置顶 10 个会话")
	case errors.Is(err, messaging.ErrConflict):
		writeAPIError(response, http.StatusConflict, "MESSAGING_CONFLICT", "Messaging state conflicts with this request")
	case errors.Is(err, messaging.ErrTooManyMentions):
		writeAPIError(response, http.StatusBadRequest, "TOO_MANY_MENTIONS", "Message contains too many mentions")
	case errors.Is(err, messaging.ErrInvalidInput), errors.Is(err, messaging.ErrUnsupportedType):
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", "Messaging request is invalid")
	case errors.Is(err, messaging.ErrUnavailable), errors.Is(err, messaging.ErrOutboxUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "MESSAGING_SERVICE_UNAVAILABLE", "Messaging service is unavailable")
	default:
		s.logger.Error("messaging request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "MESSAGING_INTERNAL_ERROR", "Messaging request failed")
	}
}

func (s *server) publishEventAvailable(userIDs []uuid.UUID, reason string) {
	seen := make(map[uuid.UUID]struct{}, len(userIDs))
	for _, userID := range userIDs {
		if userID == uuid.Nil {
			continue
		}
		if _, ok := seen[userID]; ok {
			continue
		}
		seen[userID] = struct{}{}
		identity := userID.String()
		envelope := protocol.OutboundEnvelope{
			Type:    protocol.TypeEventAvailable,
			EventID: s.nextEventID(),
			Payload: protocol.EventAvailablePayload{Reason: reason},
		}
		s.hub.publish(identity, envelope)
		if s.realtimeEventBus != nil {
			remoteEnvelope := envelope
			remoteEnvelope.EventID = 0
			s.enqueueRealtimeBusHint(identity, remoteEnvelope)
		}
	}
}

func (s *server) handleMessageTranscription(response http.ResponseWriter, request *http.Request, principal account.Principal, messageID uuid.UUID) {
	if s.transcription == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "VOICE_TRANSCRIPTION_UNAVAILABLE", "Voice transcription is not configured")
		return
	}
	var result transcription.Transcription
	var err error
	switch request.Method {
	case http.MethodGet:
		result, err = s.transcription.Get(request.Context(), principal, messageID)
	case http.MethodPost:
		result, err = s.transcription.Request(request.Context(), principal, messageID)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPost)
		return
	}
	if err != nil {
		s.writeTranscriptionError(response, request, err)
		return
	}
	status := http.StatusOK
	if request.Method == http.MethodPost && (result.Status == transcription.StatusPending || result.Status == transcription.StatusRunning) {
		status = http.StatusAccepted
	}
	writeSuccess(response, status, result)
}

func (s *server) handleVoiceTranscriptionPreferences(response http.ResponseWriter, request *http.Request) {
	if s.transcription == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "VOICE_TRANSCRIPTION_UNAVAILABLE", "Voice transcription is not configured")
		return
	}
	principal, ok := s.requirePrincipal(response, request)
	if !ok {
		return
	}
	switch request.Method {
	case http.MethodGet:
		result, err := s.transcription.GetPreferences(request.Context(), principal)
		if err != nil {
			s.writeTranscriptionError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	case http.MethodPatch, http.MethodPut:
		if !requireJSON(response, request) {
			return
		}
		var input transcription.UpdatePreferencesInput
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_VOICE_TRANSCRIPTION_REQUEST", err.Error())
			return
		}
		result, err := s.transcription.UpdatePreferences(request.Context(), principal, input)
		if err != nil {
			s.writeTranscriptionError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
	default:
		methodNotAllowed(response, http.MethodGet, http.MethodPatch, http.MethodPut)
	}
}

func (s *server) writeTranscriptionError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, transcription.ErrInvalidInput):
		writeAPIError(response, http.StatusBadRequest, "INVALID_VOICE_TRANSCRIPTION_REQUEST", "Voice transcription request is invalid")
	case errors.Is(err, transcription.ErrNotVoice):
		writeAPIError(response, http.StatusUnprocessableEntity, "VOICE_TRANSCRIPTION_NOT_VOICE", "Only voice messages can be transcribed")
	case errors.Is(err, transcription.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "VOICE_TRANSCRIPTION_NOT_FOUND", "Voice message or transcription was not found")
	case errors.Is(err, transcription.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "VOICE_TRANSCRIPTION_UNAVAILABLE", "Voice transcription provider is unavailable")
	default:
		s.logger.Error("voice transcription request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "VOICE_TRANSCRIPTION_INTERNAL_ERROR", "Voice transcription request failed")
	}
}

type realtimeBusDelivery struct {
	userID   string
	envelope protocol.OutboundEnvelope
}

func (s *server) enqueueRealtimeBusHint(userID string, envelope protocol.OutboundEnvelope) {
	if s.realtimePublishQueue == nil {
		return
	}
	select {
	case s.realtimePublishQueue <- realtimeBusDelivery{userID: userID, envelope: envelope}:
	default:
		if s.metrics != nil {
			s.metrics.RealtimeQueueDropped()
		}
		s.logger.Warn("cross-node realtime hint queue full; client sync will recover")
	}
}

func (s *server) publishRealtimeBusHints() {
	for delivery := range s.realtimePublishQueue {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := s.realtimeEventBus.Publish(ctx, delivery.userID, delivery.envelope)
		cancel()
		if err != nil {
			if s.metrics != nil {
				s.metrics.RealtimePublishFailure("publish")
			}
			s.logger.Warn("cross-node realtime hint publish failed; client sync will recover", "error", err)
		}
	}
}

func (s *server) consumeRealtimeEventBus() {
	for {
		err := s.realtimeEventBus.Subscribe(context.Background(), func(userID string, envelope protocol.OutboundEnvelope) {
			envelope.EventID = s.nextEventID()
			s.hub.publish(userID, envelope)
		})
		if err != nil {
			if s.metrics != nil {
				s.metrics.RealtimePublishFailure("subscribe")
				s.metrics.RedisReconnect()
			}
			s.logger.Warn("cross-node realtime subscription stopped; retrying", "error", err)
		}
		time.Sleep(time.Second)
	}
}

func parseBoundedIntQuery(response http.ResponseWriter, request *http.Request, name string, defaultValue, minimum, maximum int) (int, bool) {
	raw := strings.TrimSpace(request.URL.Query().Get(name))
	if raw == "" {
		return defaultValue, true
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < minimum || value > maximum {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", name+" is out of range")
		return 0, false
	}
	return value, true
}

func parseBoundedInt64Query(response http.ResponseWriter, request *http.Request, name string, defaultValue, minimum int64) (int64, bool) {
	raw := strings.TrimSpace(request.URL.Query().Get(name))
	if raw == "" {
		return defaultValue, true
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || value < minimum {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", name+" must be a non-negative integer")
		return 0, false
	}
	return value, true
}
