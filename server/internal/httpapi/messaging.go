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
	"github.com/google/uuid"
)

type MessagingService interface {
	EnsureDirectConversation(ctx context.Context, principal account.Principal, targetUserID uuid.UUID) (messaging.Conversation, error)
	ListConversations(ctx context.Context, principal account.Principal, limit int) ([]messaging.Conversation, error)
	GetConversation(ctx context.Context, principal account.Principal, conversationID uuid.UUID) (messaging.Conversation, error)
	UpdatePreferences(ctx context.Context, principal account.Principal, conversationID uuid.UUID, input messaging.UpdatePreferencesInput) (messaging.Conversation, error)
	MarkRead(ctx context.Context, principal account.Principal, conversationID uuid.UUID, sequence int64) (messaging.MarkReadResult, []uuid.UUID, error)
	SendMessage(ctx context.Context, principal account.Principal, conversationID uuid.UUID, input messaging.SendMessageInput) (messaging.SendResult, error)
	ListMessages(ctx context.Context, principal account.Principal, conversationID uuid.UUID, beforeSequence int64, limit int) (messaging.MessagePage, error)
	GetMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (messaging.Message, error)
	RecallMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (messaging.SendResult, error)
	DeleteMessageLocally(ctx context.Context, principal account.Principal, messageID uuid.UUID) error
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
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		result, err := s.messaging.GetConversation(request.Context(), principal, conversationID)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
		return
	}

	switch parts[1] {
	case "messages":
		s.handleConversationMessages(response, request, principal, conversationID)
	case "read":
		s.handleConversationRead(response, request, principal, conversationID)
	case "preferences":
		s.handleConversationPreferences(response, request, principal, conversationID)
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
		if request.Method != http.MethodGet {
			methodNotAllowed(response, http.MethodGet)
			return
		}
		result, err := s.messaging.GetMessage(request.Context(), principal, messageID)
		if err != nil {
			s.writeMessagingError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, result)
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
	default:
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
	}
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

func (s *server) writeMessagingError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, messaging.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested messaging resource was not found")
	case errors.Is(err, messaging.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "MESSAGING_FORBIDDEN", "Messaging operation is not allowed")
	case errors.Is(err, messaging.ErrBlocked):
		writeAPIError(response, http.StatusForbidden, "MESSAGING_BLOCKED", "Messaging is blocked for this relationship")
	case errors.Is(err, messaging.ErrConflict):
		writeAPIError(response, http.StatusConflict, "MESSAGING_CONFLICT", "Messaging state conflicts with this request")
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
		s.logger.Warn("cross-node realtime hint queue full; client sync will recover", "userId", userID)
	}
}

func (s *server) publishRealtimeBusHints() {
	for delivery := range s.realtimePublishQueue {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := s.realtimeEventBus.Publish(ctx, delivery.userID, delivery.envelope)
		cancel()
		if err != nil {
			s.logger.Warn("cross-node realtime hint publish failed; client sync will recover", "userId", delivery.userID, "error", err)
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
