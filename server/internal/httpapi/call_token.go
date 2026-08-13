package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/livekit/protocol/auth"
)

const maxCallTokenRequestBytes = 4 * 1024

var safeCallIdentifier = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

type callTokenRequest struct {
	RoomName            string `json:"room_name"`
	ParticipantIdentity string `json:"participant_identity"`
	ParticipantName     string `json:"participant_name"`
}

type callTokenResponse struct {
	ServerURL        string    `json:"server_url"`
	ParticipantToken string    `json:"participant_token"`
	ExpiresAt        time.Time `json:"expires_at"`
}

type formalCallTokenResponse struct {
	ServerURL           string `json:"server_url"`
	Token               string `json:"token"`
	RoomName            string `json:"room_name"`
	ParticipantIdentity string `json:"participant_identity"`
	ExpiresInSeconds    int64  `json:"expires_in_seconds"`
}

func (s *server) handleCallToken(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if s.liveKitURL == "" || s.liveKitAPIKey == "" || s.liveKitAPISecret == "" {
		writeAPIError(response, http.StatusServiceUnavailable, "CALL_SERVICE_UNAVAILABLE", "Call service is not configured")
		return
	}
	if !isJSONContentType(request.Header.Get("Content-Type")) {
		writeAPIError(response, http.StatusUnsupportedMediaType, "JSON_REQUIRED", "Content-Type must be application/json")
		return
	}

	var input callTokenRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}

	input.RoomName = strings.TrimSpace(input.RoomName)
	input.ParticipantIdentity = strings.TrimSpace(input.ParticipantIdentity)
	input.ParticipantName = strings.TrimSpace(input.ParticipantName)
	if err := validateCallTokenRequest(input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_CALL_IDENTITY", err.Error())
		return
	}

	s.issueCallToken(
		response,
		request,
		input.RoomName,
		input.ParticipantIdentity,
		input.ParticipantName,
	)
}

func (s *server) issueCallToken(
	response http.ResponseWriter,
	request *http.Request,
	roomName string,
	participantIdentity string,
	participantName string,
) {
	token, ok := s.mintCallToken(response, roomName, participantIdentity, participantName)
	if !ok {
		return
	}

	writeJSON(response, http.StatusOK, callTokenResponse{
		ServerURL:        s.resolveLiveKitURL(request),
		ParticipantToken: token,
		ExpiresAt:        s.now().UTC().Add(s.callTokenTTL),
	})
}

func (s *server) issueFormalCallToken(
	response http.ResponseWriter,
	request *http.Request,
	roomName string,
	participantIdentity string,
	participantName string,
) {
	token, ok := s.mintCallToken(response, roomName, participantIdentity, participantName)
	if !ok {
		return
	}

	writeJSON(response, http.StatusOK, formalCallTokenResponse{
		ServerURL:           s.resolveLiveKitURL(request),
		Token:               token,
		RoomName:            roomName,
		ParticipantIdentity: participantIdentity,
		ExpiresInSeconds:    int64(s.callTokenTTL / time.Second),
	})
}

func (s *server) mintCallToken(
	response http.ResponseWriter,
	roomName string,
	participantIdentity string,
	participantName string,
) (string, bool) {
	if s.liveKitURL == "" || s.liveKitAPIKey == "" || s.liveKitAPISecret == "" {
		writeAPIError(response, http.StatusServiceUnavailable, "CALL_SERVICE_UNAVAILABLE", "Call service is not configured")
		return "", false
	}

	grant := &auth.VideoGrant{
		RoomJoin: true,
		Room:     roomName,
	}
	grant.SetCanPublish(true)
	grant.SetCanSubscribe(true)
	grant.SetCanPublishData(false)

	token, err := auth.NewAccessToken(s.liveKitAPIKey, s.liveKitAPISecret).
		SetIdentity(participantIdentity).
		SetName(participantName).
		SetVideoGrant(grant).
		SetValidFor(s.callTokenTTL).
		ToJWT()
	if err != nil {
		writeAPIError(response, http.StatusInternalServerError, "TOKEN_ISSUE_FAILED", "Unable to issue call token")
		return "", false
	}
	return token, true
}

func (s *server) resolveLiveKitURL(request *http.Request) string {
	if s.liveKitURL != "auto" {
		return s.liveKitURL
	}

	host := request.Host
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		host = parsedHost
	}
	if host == "" {
		host = "127.0.0.1"
	}

	scheme := "ws"
	if request.TLS != nil {
		scheme = "wss"
	}
	return scheme + "://" + net.JoinHostPort(host, strconv.Itoa(s.liveKitPublicPort))
}

func decodeSingleJSON(response http.ResponseWriter, request *http.Request, destination any) error {
	request.Body = http.MaxBytesReader(response, request.Body, maxCallTokenRequestBytes)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return errors.New("Request body must be a valid JSON object")
	}

	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("Request body must contain exactly one JSON object")
	}
	return nil
}

func isJSONContentType(raw string) bool {
	mediaType, _, err := mime.ParseMediaType(raw)
	return err == nil && mediaType == "application/json"
}

func validateCallTokenRequest(input callTokenRequest) error {
	if !safeCallIdentifier.MatchString(input.RoomName) {
		return errors.New("room_name must be 1-64 ASCII letters, numbers, dots, underscores, or hyphens")
	}
	if !safeCallIdentifier.MatchString(input.ParticipantIdentity) {
		return errors.New("participant_identity must be 1-64 ASCII letters, numbers, dots, underscores, or hyphens")
	}
	if input.ParticipantName == "" || !utf8.ValidString(input.ParticipantName) || utf8.RuneCountInString(input.ParticipantName) > 80 {
		return errors.New("participant_name must contain 1-80 valid Unicode characters")
	}
	for _, character := range input.ParticipantName {
		if unicode.IsControl(character) {
			return errors.New("participant_name must not contain control characters")
		}
	}
	return nil
}

func writeAPIError(response http.ResponseWriter, status int, code, message string) {
	errorBody := map[string]string{
		"code":    code,
		"message": message,
	}
	if requestID := strings.TrimSpace(response.Header().Get(requestIDHeader)); requestID != "" {
		errorBody["requestId"] = requestID
	}
	writeJSON(response, status, map[string]any{"error": errorBody})
}
