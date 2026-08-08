package httpapi

import (
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

type instanceFeatures struct {
	Calls            bool   `json:"calls"`
	RegistrationMode string `json:"registrationMode"`
}

type instanceDocument struct {
	Name        string           `json:"name"`
	APIVersion  string           `json:"apiVersion"`
	APIBaseURL  string           `json:"apiBaseUrl"`
	RealtimeURL string           `json:"realtimeUrl"`
	LiveKitURL  string           `json:"liveKitUrl"`
	Features    instanceFeatures `json:"features"`
}

func (s *server) handleInstance(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	writeSuccess(response, http.StatusOK, s.buildInstanceDocument(request))
}

func (s *server) handleWellKnownClient(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	writeJSON(response, http.StatusOK, s.buildInstanceDocument(request))
}

func (s *server) buildInstanceDocument(request *http.Request) instanceDocument {
	baseURL := s.resolvePublicBaseURL(request)
	return instanceDocument{
		Name:        s.instanceName,
		APIVersion:  "v1",
		APIBaseURL:  baseURL + "/api/v1",
		RealtimeURL: websocketURL(baseURL) + "/api/v1/realtime",
		LiveKitURL:  s.resolveLiveKitURL(request),
		Features: instanceFeatures{
			Calls:            strings.TrimSpace(s.liveKitURL) != "",
			RegistrationMode: s.registrationMode,
		},
	}
}

func (s *server) resolvePublicBaseURL(request *http.Request) string {
	if s.publicBaseURL != "" {
		return s.publicBaseURL
	}

	scheme := "http"
	if request.TLS != nil {
		scheme = "https"
	}
	host := strings.TrimSpace(request.Host)
	if host == "" {
		host = net.JoinHostPort("127.0.0.1", strconv.Itoa(18473))
	}
	return scheme + "://" + host
}

func normalizeRegistrationMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "open", "invite", "approval", "closed":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "closed"
	}
}

func websocketURL(baseURL string) string {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return ""
	}
	switch parsed.Scheme {
	case "https":
		parsed.Scheme = "wss"
	case "http":
		parsed.Scheme = "ws"
	default:
		return ""
	}
	return strings.TrimRight(parsed.String(), "/")
}

func writeSuccess(response http.ResponseWriter, status int, data any) {
	writeJSON(response, status, map[string]any{
		"data":      data,
		"requestId": strings.TrimSpace(response.Header().Get(requestIDHeader)),
	})
}
