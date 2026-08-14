package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/protocol"
	"example.com/selfhosted-im/server/internal/transcription"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/google/uuid"
)

const (
	serviceName                       = "im-realtime-poc"
	maxWebSocketBytes                 = 16 * 1024
	maxAuthenticatedSocketConnections = 16
	webSocketHelloTimeout             = 10 * time.Second
	writeTimeout                      = 5 * time.Second
)

type ReadinessCheck func(context.Context) error

type RuntimeMetrics interface {
	HTTPRequestStarted()
	HTTPRequestFinished(method, route string, status int, duration time.Duration)
	SetDependencyHealth(name string, healthy bool)
	WebSocketOpened(mode string)
	WebSocketClosed(mode string)
	RealtimePublishFailure(reason string)
	RealtimeQueueDropped()
	RedisReconnect()
}

type TranscriptionService interface {
	Request(context.Context, account.Principal, uuid.UUID) (transcription.Transcription, error)
	Get(context.Context, account.Principal, uuid.UUID) (transcription.Transcription, error)
	GetPreferences(context.Context, account.Principal) (transcription.Preferences, error)
	UpdatePreferences(context.Context, account.Principal, transcription.UpdatePreferencesInput) (transcription.Preferences, error)
}

type RealtimeEventBus interface {
	Publish(ctx context.Context, userID string, envelope protocol.OutboundEnvelope) error
	Subscribe(ctx context.Context, deliver func(userID string, envelope protocol.OutboundEnvelope)) error
}

type Config struct {
	Version                    string
	PublicBaseURL              string
	InstanceName               string
	RegistrationMode           string
	AllowedOrigins             []string
	AllowedHTTPOrigins         []string
	LiveKitURL                 string
	LiveKitPublicPort          int
	LiveKitAPIKey              string
	LiveKitAPISecret           string
	CallTokenTTL               time.Duration
	CallRingTimeout            time.Duration
	ReadinessChecks            map[string]ReadinessCheck
	AuthService                AuthService
	AdminService               AdminService
	TelegramIntegrationService TelegramIntegrationService
	AdminWebRoot               string
	ContactsService            ContactsService
	GroupsService              GroupsService
	CallsService               CallsService
	MessagingService           MessagingService
	TranscriptionService       TranscriptionService
	MediaService               MediaService
	StickersService            StickersService
	MomentsService             MomentsService
	QRService                  QRService
	PushService                PushService
	DataRightsService          DataRightsService
	PushAvatarSecret           string
	RealtimeEventBus           RealtimeEventBus
	Metrics                    RuntimeMetrics
	Logger                     *slog.Logger
	Now                        func() time.Time
}

type server struct {
	version              string
	publicBaseURL        string
	instanceName         string
	registrationMode     string
	allowedOrigins       []string
	allowedHTTPOrigins   []string
	liveKitURL           string
	liveKitPublicPort    int
	liveKitAPIKey        string
	liveKitAPISecret     string
	callTokenTTL         time.Duration
	callRingTimeout      time.Duration
	now                  func() time.Time
	logger               *slog.Logger
	readinessChecks      map[string]ReadinessCheck
	auth                 AuthService
	admin                AdminService
	telegramIntegration  TelegramIntegrationService
	adminWebRoot          string
	contacts             ContactsService
	groups               GroupsService
	formalCalls          CallsService
	messaging            MessagingService
	transcription        TranscriptionService
	media                MediaService
	stickers             StickersService
	moments              MomentsService
	qr                   QRService
	push                 PushService
	dataRights           DataRightsService
	pushAvatarSecret     string
	realtimeEventBus     RealtimeEventBus
	metrics              RuntimeMetrics
	realtimePublishQueue chan realtimeBusDelivery
	eventSequence        atomic.Int64
	legacyCalls          *callStore
	hub                  *socketHub
}

func NewHandler(config Config) http.Handler {
	version := strings.TrimSpace(config.Version)
	if version == "" {
		version = "dev"
	}

	now := config.Now
	if now == nil {
		now = time.Now
	}

	callTokenTTL := config.CallTokenTTL
	if callTokenTTL <= 0 || callTokenTTL > time.Hour {
		callTokenTTL = 15 * time.Minute
	}

	callRingTimeout := config.CallRingTimeout
	if callRingTimeout <= 0 || callRingTimeout > 5*time.Minute {
		callRingTimeout = 45 * time.Second
	}

	liveKitPublicPort := config.LiveKitPublicPort
	if liveKitPublicPort <= 0 || liveKitPublicPort > 65535 {
		liveKitPublicPort = 7880
	}

	logger := config.Logger
	if logger == nil {
		logger = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}

	instanceName := strings.TrimSpace(config.InstanceName)
	if instanceName == "" {
		instanceName = "DD"
	}

	s := &server{
		version:             version,
		publicBaseURL:       strings.TrimRight(strings.TrimSpace(config.PublicBaseURL), "/"),
		instanceName:        instanceName,
		registrationMode:    normalizeRegistrationMode(config.RegistrationMode),
		allowedOrigins:      append([]string(nil), config.AllowedOrigins...),
		allowedHTTPOrigins:  append([]string(nil), config.AllowedHTTPOrigins...),
		liveKitURL:          strings.TrimSpace(config.LiveKitURL),
		liveKitPublicPort:   liveKitPublicPort,
		liveKitAPIKey:       strings.TrimSpace(config.LiveKitAPIKey),
		liveKitAPISecret:    strings.TrimSpace(config.LiveKitAPISecret),
		callTokenTTL:        callTokenTTL,
		callRingTimeout:     callRingTimeout,
		now:                 now,
		logger:              logger,
		readinessChecks:     copyReadinessChecks(config.ReadinessChecks),
		auth:                config.AuthService,
		admin:               config.AdminService,
		telegramIntegration: config.TelegramIntegrationService,
		adminWebRoot:         strings.TrimSpace(config.AdminWebRoot),
		contacts:            config.ContactsService,
		groups:              config.GroupsService,
		formalCalls:         config.CallsService,
		messaging:           config.MessagingService,
		transcription:       config.TranscriptionService,
		media:               config.MediaService,
		stickers:            config.StickersService,
		moments:             config.MomentsService,
		qr:                  config.QRService,
		push:                config.PushService,
		dataRights:          config.DataRightsService,
		pushAvatarSecret:    strings.TrimSpace(config.PushAvatarSecret),
		realtimeEventBus:    config.RealtimeEventBus,
		metrics:             config.Metrics,
		legacyCalls:         newCallStore(),
		hub:                 newSocketHub(),
	}
	s.eventSequence.Store(now().UTC().UnixMicro())
	if s.realtimeEventBus != nil {
		s.realtimePublishQueue = make(chan realtimeBusDelivery, 4096)
		go s.publishRealtimeBusHints()
		go s.consumeRealtimeEventBus()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openimx/client", s.handleWellKnownClient)
	mux.HandleFunc("/admin", s.handleAdminWeb)
	mux.HandleFunc("/admin/", s.handleAdminWeb)
	mux.HandleFunc("/push-assets/avatars/", s.handlePushAvatarAsset)
	mux.HandleFunc("/api/v1/instance", s.handleInstance)
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/live", s.handleLive)
	mux.HandleFunc("/ready", s.handleReady)
	mux.HandleFunc("/version", s.handleVersion)
	mux.HandleFunc("/api/v1/system/live", s.handleLive)
	mux.HandleFunc("/api/v1/system/ready", s.handleReady)
	mux.HandleFunc("/api/v1/system/version", s.handleVersion)
	mux.HandleFunc("/api/v1/auth/register/email/send-code", s.handleAuthEmailCodes)
	mux.HandleFunc("/api/v1/auth/register", s.handleAuthRegister)
	mux.HandleFunc("/api/v1/auth/login", s.handleAuthLogin)
	mux.HandleFunc("/api/v1/auth/token/refresh", s.handleAuthRefresh)
	mux.HandleFunc("/api/v1/auth/password/reset/send-code", s.handlePasswordResetCode)
	mux.HandleFunc("/api/v1/auth/password/reset", s.handlePasswordReset)
	mux.HandleFunc("/api/v1/auth/logout-all", s.handleLogoutAll)
	mux.HandleFunc("/api/v1/reports", s.handleReports)
	mux.HandleFunc("/api/v1/reports/", s.handleReportByID)
	mux.HandleFunc("/api/v1/admin/auth/login", s.handleAdminLogin)
	mux.HandleFunc("/api/v1/admin/auth/mfa/enroll", s.handleAdminMFAEnroll)
	mux.HandleFunc("/api/v1/admin/auth/mfa/enroll/verify", s.handleAdminMFAEnrollVerify)
	mux.HandleFunc("/api/v1/admin/auth/mfa/verify", s.handleAdminMFAVerify)
	mux.HandleFunc("/api/v1/admin/auth/logout", s.handleAdminLogout)
	mux.HandleFunc("/api/v1/admin/session", s.handleAdminSession)
	mux.HandleFunc("/api/v1/admin/sessions", s.handleAdminSessions)
	mux.HandleFunc("/api/v1/admin/sessions/", s.handleAdminSessionByID)
	mux.HandleFunc("/api/v1/admin/mfa/recovery/regenerate", s.handleAdminRecoveryRegenerate)
	mux.HandleFunc("/api/v1/admin/reports", s.handleAdminReports)
	mux.HandleFunc("/api/v1/admin/reports/", s.handleAdminReportByID)
	mux.HandleFunc("/api/v1/admin/users", s.handleAdminUsers)
	mux.HandleFunc("/api/v1/admin/users/", s.handleAdminUserByID)
	mux.HandleFunc("/api/v1/admin/audit", s.handleAdminAudit)
	mux.HandleFunc("/api/v1/admin/integrations/telegram-sticker", s.handleAdminTelegramIntegration)
	mux.HandleFunc("/api/v1/admin/integrations/telegram-sticker/test", s.handleAdminTelegramIntegrationTest)
	mux.HandleFunc("/api/v1/me", s.handleMe)
	mux.HandleFunc("/api/v1/me/email/send-code", s.handleMeEmailChangeCode)
	mux.HandleFunc("/api/v1/me/email", s.handleMeEmail)
	mux.HandleFunc("/api/v1/me/avatar", s.handleMeAvatar)
	mux.HandleFunc("/api/v1/devices", s.handleDevices)
	mux.HandleFunc("/api/v1/devices/", s.handleDeviceByID)
	mux.HandleFunc("/api/v1/users/by-handle/", s.handleUserByHandle)
	mux.HandleFunc("/api/v1/users/mention-suggestions", s.handleMentionSuggestions)
	mux.HandleFunc("/api/v1/users/", s.handleUserByID)
	mux.HandleFunc("/api/v1/avatars/", s.handleUserAvatar)
	mux.HandleFunc("/api/v1/contact-requests", s.handleContactRequests)
	mux.HandleFunc("/api/v1/contact-requests/", s.handleContactRequestByID)
	mux.HandleFunc("/api/v1/contacts", s.handleContacts)
	mux.HandleFunc("/api/v1/contacts/", s.handleContactByUserID)
	mux.HandleFunc("/api/v1/blocks", s.handleBlocks)
	mux.HandleFunc("/api/v1/blocks/", s.handleBlockByUserID)
	mux.HandleFunc("/api/v1/groups", s.handleGroups)
	mux.HandleFunc("/api/v1/groups/", s.handleGroupByID)
	mux.HandleFunc("/api/v1/calls", s.handleFormalCalls)
	mux.HandleFunc("/api/v1/calls/active", s.handleFormalActiveCall)
	mux.HandleFunc("/api/v1/calls/", s.handleFormalCallByID)
	mux.HandleFunc("/api/v1/conversations", s.handleConversations)
	mux.HandleFunc("/api/v1/conversations/direct", s.handleDirectConversation)
	mux.HandleFunc("/api/v1/conversations/", s.handleConversationByID)
	mux.HandleFunc("/api/v1/saved-messages/conversation", s.handleSavedConversation)
	mux.HandleFunc("/api/v1/saved-messages", s.handleSavedMessages)
	mux.HandleFunc("/api/v1/messages/search", s.handleMessageSearch)
	mux.HandleFunc("/api/v1/link-preview", s.handleLinkPreview)
	mux.HandleFunc("/api/v1/messages/", s.handleMessageByID)
	mux.HandleFunc("/api/v1/media/uploads", s.handleMediaUploads)
	mux.HandleFunc("/api/v1/media/uploads/", s.handleMediaUploadByID)
	mux.HandleFunc("/api/v1/media/", s.handleMediaByID)
	mux.HandleFunc("/api/v1/stickers/custom/order", s.handleCustomStickerOrder)
	mux.HandleFunc("/api/v1/stickers/custom", s.handleCustomStickers)
	mux.HandleFunc("/api/v1/stickers/packs/telegram", s.handleTelegramStickerPackImport)
	mux.HandleFunc("/api/v1/stickers/packs/", s.handleStickerPackByID)
	mux.HandleFunc("/api/v1/stickers/packs", s.handleStickerPacks)
	mux.HandleFunc("/api/v1/moment-preferences", s.handleMomentPreferences)
	mux.HandleFunc("/api/v1/moment-preferences/", s.handleMomentPreferences)
	mux.HandleFunc("/api/v1/moment-profiles/", s.handleMomentProfile)
	mux.HandleFunc("/api/v1/moment-activity", s.handleMomentActivity)
	mux.HandleFunc("/api/v1/moment-activity/", s.handleMomentActivity)
	mux.HandleFunc("/api/v1/moments", s.handleMoments)
	mux.HandleFunc("/api/v1/moments/", s.handleMomentByID)
	mux.HandleFunc("/api/v1/qr/me", s.handleMyQR)
	mux.HandleFunc("/api/v1/group-qr-invites", s.handleGroupQRInvites)
	mux.HandleFunc("/api/v1/group-qr-invites/", s.handleGroupQRInvites)
	mux.HandleFunc("/api/v1/group-qr/redeem", s.handleGroupQRRedeem)
	mux.HandleFunc("/api/v1/qr-login", s.handleQRLoginCreate)
	mux.HandleFunc("/api/v1/qr-login/status", s.handleQRLoginStatus)
	mux.HandleFunc("/api/v1/qr-login/scan", s.handleQRLoginScan)
	mux.HandleFunc("/api/v1/qr-login/confirm", s.handleQRLoginConfirm)
	mux.HandleFunc("/api/v1/qr-login/consume", s.handleQRLoginConsume)
	mux.HandleFunc("/api/v1/voice-transcription/preferences", s.handleVoiceTranscriptionPreferences)
	mux.HandleFunc("/api/v1/push/preferences", s.handlePushPreferences)
	mux.HandleFunc("/api/v1/push/endpoints", s.handlePushEndpoints)
	mux.HandleFunc("/api/v1/push/endpoints/", s.handlePushEndpointByProvider)
	mux.HandleFunc("/api/v1/push/test", s.handlePushTest)
	mux.HandleFunc("/api/v1/data-rights/exports", s.handleDataExportRequests)
	mux.HandleFunc("/api/v1/data-rights/exports/", s.handleDataExportRequestByID)
	mux.HandleFunc("/api/v1/data-rights/account-deletion", s.handleAccountDeletionRequests)
	mux.HandleFunc("/api/v1/data-rights/account-deletion/", s.handleAccountDeletionRequestByID)
	mux.HandleFunc("/api/v1/sync", s.handleSync)
	mux.HandleFunc("/api/calls/token", s.handleCallToken)
	mux.HandleFunc("/api/calls/active", s.handleActiveCall)
	mux.HandleFunc("/api/calls/", s.handleCallByID)
	mux.HandleFunc("/api/calls", s.handleCalls)
	mux.HandleFunc("/ws", s.handleWebSocket)
	mux.HandleFunc("/api/v1/realtime", s.handleAuthenticatedWebSocket)

	handler := securityHeaders(corsMiddleware(s.allowedHTTPOrigins, s.publicBaseURL, mux))
	handler = accessLogMiddleware(s.logger, s.version, s.metrics, handler)
	return requestIDMiddleware(handler)
}

func (s *server) handleHealth(response http.ResponseWriter, request *http.Request) {
	// Compatibility alias retained for the existing PoC. New callers should use /live.
	s.handleLive(response, request)
}

func (s *server) handleLive(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}

	writeJSON(response, http.StatusOK, map[string]any{
		"status":  "ok",
		"service": serviceName,
		"time":    s.now().UTC(),
	})
}

func (s *server) handleReady(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}

	checks := make(map[string]string, len(s.readinessChecks))
	names := make([]string, 0, len(s.readinessChecks))
	for name := range s.readinessChecks {
		names = append(names, name)
	}
	sort.Strings(names)

	ready := true
	for _, name := range names {
		ctx, cancel := context.WithTimeout(request.Context(), 2*time.Second)
		err := s.readinessChecks[name](ctx)
		cancel()
		if err != nil {
			checks[name] = "failed"
			if s.metrics != nil {
				s.metrics.SetDependencyHealth(name, false)
			}
			ready = false
			continue
		}
		checks[name] = "ok"
		if s.metrics != nil {
			s.metrics.SetDependencyHealth(name, true)
		}
	}

	status := http.StatusOK
	state := "ready"
	if !ready {
		status = http.StatusServiceUnavailable
		state = "not_ready"
	}
	writeJSON(response, status, map[string]any{
		"status":  state,
		"service": serviceName,
		"checks":  checks,
		"time":    s.now().UTC(),
	})
}

func (s *server) handleVersion(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}

	writeJSON(response, http.StatusOK, map[string]string{
		"version":         s.version,
		"protocolVersion": protocol.Version,
	})
}

func (s *server) handleWebSocket(response http.ResponseWriter, request *http.Request) {
	s.handleWebSocketMode(response, request, false)
}

func (s *server) handleAuthenticatedWebSocket(response http.ResponseWriter, request *http.Request) {
	s.handleWebSocketMode(response, request, true)
}

func (s *server) handleWebSocketMode(response http.ResponseWriter, request *http.Request, requireAuthentication bool) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}

	connectionID, err := newConnectionID()
	if err != nil {
		writeJSON(response, http.StatusInternalServerError, map[string]any{
			"error": map[string]string{
				"code":    "CONNECTION_INIT_FAILED",
				"message": "Unable to initialize connection",
			},
		})
		return
	}

	var options *websocket.AcceptOptions
	if len(s.allowedOrigins) > 0 {
		options = &websocket.AcceptOptions{
			OriginPatterns: s.allowedOrigins,
		}
	}

	connection, err := websocket.Accept(response, request, options)
	if err != nil {
		return
	}
	metricMode := "legacy"
	if requireAuthentication {
		metricMode = "authenticated"
	}
	if s.metrics != nil {
		s.metrics.WebSocketOpened(metricMode)
	}
	registeredIdentity := ""
	client := &socketClient{connection: connection}
	defer func() {
		if registeredIdentity != "" {
			s.hub.unregister(registeredIdentity, client)
		}
		if s.metrics != nil {
			s.metrics.WebSocketClosed(metricMode)
		}
		forgetSocketWriteLock(connection)
		connection.CloseNow()
	}()
	connection.SetReadLimit(maxWebSocketBytes)

	ctx := context.Background()
	nextEventID := s.nextEventID

	hasHello := false
	for {
		var incoming protocol.InboundEnvelope
		readContext := ctx
		var cancel context.CancelFunc
		if requireAuthentication && !hasHello {
			readContext, cancel = context.WithTimeout(ctx, webSocketHelloTimeout)
		}
		err := wsjson.Read(readContext, connection, &incoming)
		if cancel != nil {
			cancel()
		}
		if err != nil {
			return
		}

		incoming.Type = strings.TrimSpace(incoming.Type)
		incoming.RequestID = strings.TrimSpace(incoming.RequestID)

		if !hasHello && incoming.Type != protocol.TypeHello {
			_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypeError,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Error: &protocol.APIError{
					Code:    "HELLO_REQUIRED",
					Message: "The first message must be hello",
				},
			})
			_ = connection.Close(websocket.StatusPolicyViolation, "hello required")
			return
		}

		switch incoming.Type {
		case protocol.TypeHello:
			if hasHello {
				if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
					Type:      protocol.TypeError,
					RequestID: incoming.RequestID,
					EventID:   nextEventID(),
					Error: &protocol.APIError{
						Code:    "HELLO_ALREADY_COMPLETED",
						Message: "hello may only be sent once per connection",
					},
				}); err != nil {
					return
				}
				continue
			}

			var hello protocol.HelloPayload
			if len(incoming.Payload) == 0 || json.Unmarshal(incoming.Payload, &hello) != nil || !safeCallIdentifier.MatchString(strings.TrimSpace(hello.ClientID)) {
				_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
					Type:      protocol.TypeError,
					RequestID: incoming.RequestID,
					EventID:   nextEventID(),
					Error: &protocol.APIError{
						Code:    "INVALID_HELLO",
						Message: "hello requires a non-empty clientId",
					},
				})
				_ = connection.Close(websocket.StatusPolicyViolation, "invalid hello")
				return
			}

			registeredIdentity = strings.TrimSpace(hello.ClientID)
			if requireAuthentication {
				if s.auth == nil || strings.TrimSpace(hello.AccessToken) == "" {
					_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
						Type: protocol.TypeError, RequestID: incoming.RequestID, EventID: nextEventID(),
						Error: &protocol.APIError{Code: "UNAUTHORIZED", Message: "A valid access token is required"},
					})
					_ = connection.Close(websocket.StatusPolicyViolation, "authentication required")
					return
				}
				if strings.TrimSpace(hello.ProtocolVersion) != protocol.Version {
					_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
						Type: protocol.TypeError, RequestID: incoming.RequestID, EventID: nextEventID(),
						Error: &protocol.APIError{Code: "PROTOCOL_VERSION_MISMATCH", Message: "Unsupported realtime protocol version"},
					})
					_ = connection.Close(websocket.StatusPolicyViolation, "protocol version mismatch")
					return
				}
				principal, authErr := s.auth.AuthenticateAccessToken(ctx, strings.TrimSpace(hello.AccessToken))
				if authErr != nil {
					_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
						Type: protocol.TypeError, RequestID: incoming.RequestID, EventID: nextEventID(),
						Error: &protocol.APIError{Code: "UNAUTHORIZED", Message: "A valid access token is required"},
					})
					_ = connection.Close(websocket.StatusPolicyViolation, "authentication failed")
					return
				}
				registeredIdentity = principal.UserID.String()
			}

			hasHello = true
			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypeHelloAck,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Payload: protocol.HelloAckPayload{
					ConnectionID:    connectionID,
					ProtocolVersion: protocol.Version,
				},
			}); err != nil {
				return
			}

			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:    protocol.TypeServerReady,
				EventID: nextEventID(),
				Payload: protocol.ServerReadyPayload{
					ServerTime: s.now().UTC().Format(time.RFC3339Nano),
				},
			}); err != nil {
				return
			}
			if requireAuthentication {
				if !s.hub.tryRegister(registeredIdentity, client, maxAuthenticatedSocketConnections) {
					_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
						Type: protocol.TypeError, EventID: nextEventID(),
						Error: &protocol.APIError{Code: "CONNECTION_LIMIT_REACHED", Message: "Too many realtime connections for this account"},
					})
					_ = connection.Close(websocket.StatusPolicyViolation, "connection limit reached")
					return
				}
			} else {
				s.hub.register(registeredIdentity, client)
			}

		case protocol.TypePing:
			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypePong,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Payload: map[string]string{
					"serverTime": s.now().UTC().Format(time.RFC3339Nano),
				},
			}); err != nil {
				return
			}

		default:
			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypeError,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Error: &protocol.APIError{
					Code:    "UNKNOWN_EVENT_TYPE",
					Message: "Unsupported WebSocket event type",
				},
			}); err != nil {
				return
			}
		}
	}
}

func (s *server) nextEventID() int64 {
	return s.eventSequence.Add(1)
}

func writeSocket(parent context.Context, connection *websocket.Conn, message protocol.OutboundEnvelope) error {
	lock := socketWriteLock(connection)
	lock.Lock()
	defer lock.Unlock()

	ctx, cancel := context.WithTimeout(parent, writeTimeout)
	defer cancel()
	return wsjson.Write(ctx, connection, message)
}

func newConnectionID() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func copyReadinessChecks(input map[string]ReadinessCheck) map[string]ReadinessCheck {
	checks := make(map[string]ReadinessCheck, len(input))
	for name, check := range input {
		name = strings.TrimSpace(name)
		if name == "" || check == nil {
			continue
		}
		checks[name] = check
	}
	return checks
}

func methodNotAllowed(response http.ResponseWriter, allowedMethods ...string) {
	response.Header().Set("Allow", strings.Join(allowedMethods, ", "))
	writeAPIError(response, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Method not allowed")
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	payload, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		payload, _ = json.Marshal(map[string]any{
			"error": map[string]any{
				"code":      "RESPONSE_ENCODING_FAILED",
				"message":   "Internal server error",
				"requestId": strings.TrimSpace(response.Header().Get(requestIDHeader)),
			},
		})
	}
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.WriteHeader(status)
	_, _ = response.Write(append(payload, '\n'))
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("X-Content-Type-Options", "nosniff")
		response.Header().Set("X-Frame-Options", "DENY")
		response.Header().Set("Referrer-Policy", "no-referrer")
		response.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		next.ServeHTTP(response, request)
	})
}
