package httpapi

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/protocol"
)

const (
	callKindAudio = "audio"
	callKindVideo = "video"

	callStatusRinging  = "ringing"
	callStatusAccepted = "accepted"
	callStatusRejected = "rejected"
	callStatusEnded    = "ended"
)

type callSession struct {
	ID             string     `json:"id"`
	RoomName       string     `json:"room_name"`
	CallerIdentity string     `json:"caller_identity"`
	CallerName     string     `json:"caller_name"`
	CalleeIdentity string     `json:"callee_identity"`
	Kind           string     `json:"kind"`
	Status         string     `json:"status"`
	CreatedAt      time.Time  `json:"created_at"`
	ExpiresAt      time.Time  `json:"expires_at"`
	AcceptedAt     *time.Time `json:"accepted_at,omitempty"`
	EndedAt        *time.Time `json:"ended_at,omitempty"`
	EndReason      string     `json:"end_reason,omitempty"`
}

type callStore struct {
	mu    sync.RWMutex
	calls map[string]callSession
}

func newCallStore() *callStore {
	return &callStore{calls: make(map[string]callSession)}
}

func (store *callStore) create(now time.Time, ringTimeout time.Duration, input createCallRequest) (callSession, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	for _, existing := range store.calls {
		if !isActiveCall(existing) {
			continue
		}
		if callContains(existing, input.CallerIdentity) || callContains(existing, input.CalleeIdentity) {
			return callSession{}, errCallBusy
		}
	}

	id, err := newCallID()
	if err != nil {
		return callSession{}, err
	}
	created := callSession{
		ID:             id,
		RoomName:       "call-" + id,
		CallerIdentity: input.CallerIdentity,
		CallerName:     input.CallerName,
		CalleeIdentity: input.CalleeIdentity,
		Kind:           input.Kind,
		Status:         callStatusRinging,
		CreatedAt:      now.UTC(),
		ExpiresAt:      now.UTC().Add(ringTimeout),
	}
	store.calls[id] = created
	return created, nil
}

func (store *callStore) get(id string) (callSession, bool) {
	store.mu.RLock()
	defer store.mu.RUnlock()
	call, ok := store.calls[id]
	return call, ok
}

func (store *callStore) activeFor(identity string) (callSession, bool) {
	store.mu.RLock()
	defer store.mu.RUnlock()

	var latest callSession
	found := false
	for _, call := range store.calls {
		if !isActiveCall(call) || !callContains(call, identity) {
			continue
		}
		if !found || call.CreatedAt.After(latest.CreatedAt) {
			latest = call
			found = true
		}
	}
	return latest, found
}

func (store *callStore) timeout(id string, now time.Time) (callSession, bool) {
	store.mu.Lock()
	defer store.mu.Unlock()

	call, ok := store.calls[id]
	if !ok || call.Status != callStatusRinging {
		return callSession{}, false
	}

	endedAt := now.UTC()
	call.Status = callStatusEnded
	call.EndedAt = &endedAt
	call.EndReason = "timeout"
	store.calls[id] = call
	return call, true
}

func (store *callStore) applyAction(id string, now time.Time, participantIdentity, action string) (callSession, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	call, ok := store.calls[id]
	if !ok {
		return callSession{}, errCallNotFound
	}
	if !callContains(call, participantIdentity) {
		return callSession{}, errCallForbidden
	}

	switch action {
	case "accept":
		if participantIdentity != call.CalleeIdentity {
			return callSession{}, errCallForbidden
		}
		if call.Status != callStatusRinging {
			return callSession{}, errInvalidCallTransition
		}
		acceptedAt := now.UTC()
		call.Status = callStatusAccepted
		call.AcceptedAt = &acceptedAt
	case "reject":
		if participantIdentity != call.CalleeIdentity {
			return callSession{}, errCallForbidden
		}
		if call.Status != callStatusRinging {
			return callSession{}, errInvalidCallTransition
		}
		endedAt := now.UTC()
		call.Status = callStatusRejected
		call.EndedAt = &endedAt
		call.EndReason = "rejected"
	case "hangup":
		if !isActiveCall(call) {
			return callSession{}, errInvalidCallTransition
		}
		endedAt := now.UTC()
		call.Status = callStatusEnded
		call.EndedAt = &endedAt
		if call.AcceptedAt == nil && participantIdentity == call.CallerIdentity {
			call.EndReason = "cancelled"
		} else {
			call.EndReason = "hangup"
		}
	default:
		return callSession{}, errInvalidCallAction
	}

	store.calls[id] = call
	return call, nil
}

var (
	errCallBusy              = errors.New("a participant is already in another active call")
	errCallNotFound          = errors.New("call not found")
	errCallForbidden         = errors.New("participant is not allowed to control this call")
	errInvalidCallTransition = errors.New("call action is not valid for the current state")
	errInvalidCallAction     = errors.New("unsupported call action")
)

type createCallRequest struct {
	CallerIdentity string `json:"caller_identity"`
	CallerName     string `json:"caller_name"`
	CalleeIdentity string `json:"callee_identity"`
	Kind           string `json:"kind"`
}

type callActionRequest struct {
	ParticipantIdentity string `json:"participant_identity"`
	Action              string `json:"action"`
}

type scopedCallTokenRequest struct {
	ParticipantIdentity string `json:"participant_identity"`
	ParticipantName     string `json:"participant_name"`
}

func (s *server) handleCalls(response http.ResponseWriter, request *http.Request) {
	if request.URL.Path != "/api/calls" {
		writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", "Call not found")
		return
	}
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !isJSONContentType(request.Header.Get("Content-Type")) {
		writeAPIError(response, http.StatusUnsupportedMediaType, "JSON_REQUIRED", "Content-Type must be application/json")
		return
	}

	var input createCallRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	input.CallerIdentity = strings.TrimSpace(input.CallerIdentity)
	input.CallerName = strings.TrimSpace(input.CallerName)
	input.CalleeIdentity = strings.TrimSpace(input.CalleeIdentity)
	input.Kind = strings.TrimSpace(strings.ToLower(input.Kind))
	if err := validateCreateCallRequest(input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_REQUEST", err.Error())
		return
	}

	call, err := s.calls.create(s.now(), s.callRingTimeout, input)
	if err != nil {
		if errors.Is(err, errCallBusy) {
			writeAPIError(response, http.StatusConflict, "CALL_BUSY", err.Error())
			return
		}
		writeAPIError(response, http.StatusInternalServerError, "CALL_CREATE_FAILED", "Unable to create call")
		return
	}

	s.publishCallEvent(call.CalleeIdentity, protocol.TypeCallIncoming, call)
	s.scheduleCallTimeout(call)
	writeJSON(response, http.StatusCreated, call)
}

func (s *server) handleActiveCall(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	identity := strings.TrimSpace(request.URL.Query().Get("participant_identity"))
	if !safeCallIdentifier.MatchString(identity) {
		writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_IDENTITY", "participant_identity is invalid")
		return
	}
	call, ok := s.calls.activeFor(identity)
	if !ok {
		response.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(response, http.StatusOK, call)
}

func (s *server) handleCallByID(response http.ResponseWriter, request *http.Request) {
	path := strings.TrimPrefix(request.URL.Path, "/api/calls/")
	parts := strings.Split(path, "/")
	if len(parts) != 2 || !safeCallIdentifier.MatchString(parts[0]) {
		writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", "Call not found")
		return
	}

	switch parts[1] {
	case "actions":
		s.handleCallAction(response, request, parts[0])
	case "token":
		s.handleScopedCallToken(response, request, parts[0])
	default:
		writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", "Call not found")
	}
}

func (s *server) handleCallAction(response http.ResponseWriter, request *http.Request, callID string) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !isJSONContentType(request.Header.Get("Content-Type")) {
		writeAPIError(response, http.StatusUnsupportedMediaType, "JSON_REQUIRED", "Content-Type must be application/json")
		return
	}

	var input callActionRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	input.ParticipantIdentity = strings.TrimSpace(input.ParticipantIdentity)
	input.Action = strings.TrimSpace(strings.ToLower(input.Action))
	if !safeCallIdentifier.MatchString(input.ParticipantIdentity) {
		writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_IDENTITY", "participant_identity is invalid")
		return
	}

	call, err := s.calls.applyAction(callID, s.now(), input.ParticipantIdentity, input.Action)
	if err != nil {
		switch {
		case errors.Is(err, errCallNotFound):
			writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", err.Error())
		case errors.Is(err, errCallForbidden):
			writeAPIError(response, http.StatusForbidden, "CALL_FORBIDDEN", err.Error())
		case errors.Is(err, errInvalidCallAction):
			writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_ACTION", err.Error())
		default:
			writeAPIError(response, http.StatusConflict, "INVALID_CALL_STATE", err.Error())
		}
		return
	}

	s.publishCallEvent(call.CallerIdentity, protocol.TypeCallUpdated, call)
	if call.CalleeIdentity != call.CallerIdentity {
		s.publishCallEvent(call.CalleeIdentity, protocol.TypeCallUpdated, call)
	}
	writeJSON(response, http.StatusOK, call)
}

func (s *server) handleScopedCallToken(response http.ResponseWriter, request *http.Request, callID string) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !isJSONContentType(request.Header.Get("Content-Type")) {
		writeAPIError(response, http.StatusUnsupportedMediaType, "JSON_REQUIRED", "Content-Type must be application/json")
		return
	}

	var input scopedCallTokenRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	input.ParticipantIdentity = strings.TrimSpace(input.ParticipantIdentity)
	input.ParticipantName = strings.TrimSpace(input.ParticipantName)
	if !safeCallIdentifier.MatchString(input.ParticipantIdentity) || validateDisplayName(input.ParticipantName) != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_IDENTITY", "participant identity or name is invalid")
		return
	}

	call, ok := s.calls.get(callID)
	if !ok {
		writeAPIError(response, http.StatusNotFound, "CALL_NOT_FOUND", "Call not found")
		return
	}
	if !callContains(call, input.ParticipantIdentity) {
		writeAPIError(response, http.StatusForbidden, "CALL_FORBIDDEN", "Participant is not part of this call")
		return
	}
	if call.Status != callStatusAccepted {
		writeAPIError(response, http.StatusConflict, "CALL_NOT_ACCEPTED", "Call must be accepted before joining media")
		return
	}

	s.issueCallToken(response, request, call.RoomName, input.ParticipantIdentity, input.ParticipantName)
}

func (s *server) scheduleCallTimeout(call callSession) {
	time.AfterFunc(s.callRingTimeout, func() {
		timedOut, ok := s.calls.timeout(call.ID, s.now())
		if !ok {
			return
		}
		s.publishCallEvent(timedOut.CallerIdentity, protocol.TypeCallUpdated, timedOut)
		if timedOut.CalleeIdentity != timedOut.CallerIdentity {
			s.publishCallEvent(timedOut.CalleeIdentity, protocol.TypeCallUpdated, timedOut)
		}
	})
}

func (s *server) publishCallEvent(identity, eventType string, call callSession) {
	s.hub.publish(identity, protocol.OutboundEnvelope{
		Type:    eventType,
		EventID: s.nextEventID(),
		Payload: call,
	})
}

func validateCreateCallRequest(input createCallRequest) error {
	if !safeCallIdentifier.MatchString(input.CallerIdentity) {
		return errors.New("caller_identity is invalid")
	}
	if !safeCallIdentifier.MatchString(input.CalleeIdentity) {
		return errors.New("callee_identity is invalid")
	}
	if input.CallerIdentity == input.CalleeIdentity {
		return errors.New("caller and callee must be different")
	}
	if err := validateDisplayName(input.CallerName); err != nil {
		return err
	}
	if input.Kind != callKindAudio && input.Kind != callKindVideo {
		return errors.New("kind must be audio or video")
	}
	return nil
}

func validateDisplayName(value string) error {
	if value == "" || !utf8.ValidString(value) || utf8.RuneCountInString(value) > 80 {
		return errors.New("caller_name must contain 1-80 valid Unicode characters")
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return errors.New("caller_name must not contain control characters")
		}
	}
	return nil
}

func isActiveCall(call callSession) bool {
	return call.Status == callStatusRinging || call.Status == callStatusAccepted
}

func callContains(call callSession, identity string) bool {
	return call.CallerIdentity == identity || call.CalleeIdentity == identity
}

func newCallID() (string, error) {
	buffer := make([]byte, 12)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}
