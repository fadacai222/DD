package httpapi

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/admin"
	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
)

type adminAccountCreateRequest struct {
	Email    string     `json:"email"`
	Password string     `json:"password"`
	Role     admin.Role `json:"role"`
}

type adminAccountUpdateRequest struct {
	Role   admin.Role `json:"role"`
	Status string     `json:"status"`
	Reason string     `json:"reason"`
}

type adminRegistrationModeRequest struct {
	Mode   string `json:"mode"`
	Reason string `json:"reason"`
}

type adminServiceHealth struct {
	Name    string `json:"name"`
	Status  string `json:"status"`
	Detail  string `json:"detail,omitempty"`
	Checked string `json:"checkedAt,omitempty"`
}

func (s *server) handleAdminDashboard(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	result, err := s.admin.Dashboard(request.Context(), principal)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleAdminGroups(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	items, err := s.admin.ListGroups(request.Context(), principal, request.URL.Query().Get("status"), request.URL.Query().Get("q"), queryLimit(request, 50))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleAdminMoments(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	items, err := s.admin.ListMoments(request.Context(), principal, request.URL.Query().Get("status"), request.URL.Query().Get("q"), queryLimit(request, 50))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"items": items})
}

func (s *server) handleAdminStorage(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	result, err := s.admin.StorageSnapshot(request.Context(), principal)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleAdminPush(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	result, err := s.admin.PushSnapshot(request.Context(), principal)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleAdminRTC(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, false)
	if !ok {
		return
	}
	result, err := s.admin.RTCSnapshot(request.Context(), principal)
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleAdminSettings(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	if _, _, _, ok := s.requireAdminPrincipal(response, request, false); !ok {
		return
	}
	mode := s.currentRegistrationMode()
	openAvailable := false
	if s.registrationControl != nil {
		openAvailable = s.registrationControl.OpenAvailable()
	}
	source := "ENVIRONMENT"
	persistedMode := ""
	var updatedAt *time.Time
	if s.admin != nil {
		setting, err := s.admin.LoadRuntimeSetting(request.Context(), admin.SettingRegistrationMode)
		if err == nil {
			source = "ADMIN_OVERRIDE"
			persistedMode = setting.Value
			value := setting.UpdatedAt
			updatedAt = &value
		} else if !errors.Is(err, admin.ErrNotFound) {
			s.writeAdminError(response, request, err)
			return
		}
	}
	writeSuccess(response, http.StatusOK, map[string]any{
		"registrationMode": mode, "persistedRegistrationMode": persistedMode, "registrationOpenAvailable": openAvailable, "source": source, "updatedAt": updatedAt,
	})
}

func (s *server) handleAdminRegistrationSetting(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPut {
		methodNotAllowed(response, http.MethodPut)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, true)
	if !ok {
		return
	}
	if s.registrationControl == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "REGISTRATION_CONTROL_UNAVAILABLE", "Runtime registration control is unavailable")
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input adminRegistrationModeRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	if err := s.registrationControl.ValidateMode(input.Mode); err != nil {
		switch {
		case errors.Is(err, account.ErrRegistrationOpenUnavailable):
			writeAPIError(response, http.StatusConflict, "REGISTRATION_OPEN_UNAVAILABLE", "SMTP and email verification dependencies are not ready for open registration")
		default:
			writeAPIError(response, http.StatusBadRequest, "REGISTRATION_MODE_INVALID", "Only open or closed registration can be selected at runtime")
		}
		return
	}
	previousMode := s.registrationControl.Mode()
	if err := s.registrationControl.SetMode(input.Mode); err != nil {
		writeAPIError(response, http.StatusConflict, "REGISTRATION_MODE_INVALID", err.Error())
		return
	}
	setting, err := s.admin.SetRegistrationMode(request.Context(), principal, input.Mode, input.Reason, adminClientContext(request))
	if err != nil {
		_ = s.registrationControl.SetMode(previousMode)
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{
		"registrationMode": s.registrationControl.Mode(), "registrationOpenAvailable": s.registrationControl.OpenAvailable(),
		"source": "ADMIN_OVERRIDE", "updatedAt": setting.UpdatedAt,
	})
}

func (s *server) handleAdminAccounts(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodGet, http.MethodPost)
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, request.Method == http.MethodPost)
	if !ok {
		return
	}
	if request.Method == http.MethodGet {
		items, err := s.admin.ListAdminAccounts(request.Context(), principal)
		if err != nil {
			s.writeAdminError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"items": items})
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input adminAccountCreateRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	item, err := s.admin.CreateAdminAccount(request.Context(), principal, input.Email, input.Password, input.Role, adminClientContext(request))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusCreated, item)
}

func (s *server) handleAdminAccountByID(response http.ResponseWriter, request *http.Request) {
	relative := strings.TrimPrefix(request.URL.Path, "/api/v1/admin/admins/")
	parts := strings.Split(strings.Trim(relative, "/"), "/")
	if len(parts) < 1 || len(parts) > 2 || parts[0] == "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	targetID, err := uuid.Parse(parts[0])
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_ID", "Administrator ID is invalid")
		return
	}
	isMFAReset := len(parts) == 2 && parts[1] == "mfa-reset"
	if len(parts) == 2 && !isMFAReset {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if (isMFAReset && request.Method != http.MethodPost) || (!isMFAReset && request.Method != http.MethodPatch) {
		if isMFAReset {
			methodNotAllowed(response, http.MethodPost)
		} else {
			methodNotAllowed(response, http.MethodPatch)
		}
		return
	}
	principal, _, _, ok := s.requireAdminPrincipal(response, request, true)
	if !ok {
		return
	}
	if !requireJSON(response, request) {
		return
	}
	if isMFAReset {
		var input adminReasonRequest
		if err := decodeSingleJSON(response, request, &input); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
			return
		}
		if err := s.admin.ResetAdminMFA(request.Context(), principal, targetID, input.Reason, adminClientContext(request)); err != nil {
			s.writeAdminError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusOK, map[string]any{"reset": true})
		return
	}
	var input adminAccountUpdateRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_ADMIN_REQUEST", err.Error())
		return
	}
	item, err := s.admin.UpdateAdminAccount(request.Context(), principal, targetID, input.Role, input.Status, input.Reason, adminClientContext(request))
	if err != nil {
		s.writeAdminError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, item)
}

func (s *server) handleAdminServiceHealth(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	if _, _, _, ok := s.requireAdminPrincipal(response, request, false); !ok {
		return
	}

	checkedAt := s.now().UTC()
	items := []adminServiceHealth{{Name: "API", Status: "UP", Detail: "DD API process is serving this request", Checked: checkedAt.Format(time.RFC3339)}}
	names := make([]string, 0, len(s.readinessChecks))
	for name := range s.readinessChecks {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		ctx, cancel := context.WithTimeout(request.Context(), 2*time.Second)
		err := s.readinessChecks[name](ctx)
		cancel()
		status := "UP"
		detail := "readiness check passed"
		if err != nil {
			status = "DOWN"
			detail = "readiness check failed"
		}
		items = append(items, adminServiceHealth{Name: strings.ToUpper(name), Status: status, Detail: detail, Checked: checkedAt.Format(time.RFC3339)})
	}

	liveKitConfigured := strings.TrimSpace(s.liveKitURL) != "" && strings.TrimSpace(s.liveKitAPIKey) != "" && strings.TrimSpace(s.liveKitAPISecret) != ""
	items = append(items, configurationHealth("LIVEKIT", liveKitConfigured, "signaling/API credentials configured", checkedAt))
	if s.telegramIntegration != nil {
		status := s.telegramIntegration.Status()
		items = append(items, configurationHealth("TELEGRAM_STICKER", status.Configured, "Bot API relay configuration", checkedAt))
	} else {
		items = append(items, adminServiceHealth{Name: "TELEGRAM_STICKER", Status: "UNKNOWN", Detail: "integration controller is unavailable", Checked: checkedAt.Format(time.RFC3339)})
	}
	items = append(items, configurationHealth("OBJECT_STORAGE", s.media != nil, "media service initialized", checkedAt))
	items = append(items, configurationHealth("PUSH_SERVICE", s.push != nil, "API push service initialized; provider runtime is Worker-owned", checkedAt))
	items = append(items, configurationHealth("VOICE_TRANSCRIPTION", s.voiceTranscriptionConfigured, "provider endpoint/model configuration", checkedAt))
	items = append(items, configurationHealth("SMTP", s.smtpConfigured, "SMTP host/from configuration", checkedAt))
	items = append(items,
		adminServiceHealth{Name: "WORKER", Status: "UNKNOWN", Detail: "Worker runtime health is not directly queryable from the API process yet", Checked: checkedAt.Format(time.RFC3339)},
		adminServiceHealth{Name: "TURN_RELAY", Status: "UNKNOWN", Detail: "configuration or port reachability is not proof of a successful TURN relay", Checked: checkedAt.Format(time.RFC3339)},
	)
	writeSuccess(response, http.StatusOK, map[string]any{"items": items, "generatedAt": checkedAt})
}

func configurationHealth(name string, configured bool, detail string, checkedAt time.Time) adminServiceHealth {
	status := "NOT_CONFIGURED"
	if configured {
		status = "CONFIGURED"
	}
	return adminServiceHealth{Name: name, Status: status, Detail: detail, Checked: checkedAt.Format(time.RFC3339)}
}
