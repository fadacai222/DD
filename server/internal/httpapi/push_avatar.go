package httpapi

import (
	"fmt"
	"net/http"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/push"
	"github.com/google/uuid"
)

func (s *server) handlePushAvatarAsset(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	userID, err := uuid.Parse(strings.Trim(strings.TrimPrefix(request.URL.Path, "/push-assets/avatars/"), "/"))
	if err != nil {
		http.NotFound(response, request)
		return
	}
	expiresAt, err := time.Parse(time.RFC3339, strings.TrimSpace(request.URL.Query().Get("expires")))
	if err != nil || !push.VerifyAvatarCapability(
		s.pushAvatarSecret,
		userID,
		expiresAt,
		request.URL.Query().Get("sig"),
		s.now(),
	) {
		http.NotFound(response, request)
		return
	}
	if s.auth == nil {
		http.NotFound(response, request)
		return
	}
	avatar, err := s.auth.GetProfileAvatar(request.Context(), userID)
	if err != nil || len(avatar.Bytes) == 0 {
		http.NotFound(response, request)
		return
	}
	response.Header().Set("Content-Type", avatar.ContentType)
	response.Header().Set("Content-Length", fmt.Sprintf("%d", len(avatar.Bytes)))
	response.Header().Set("Cache-Control", "private, max-age=300")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.WriteHeader(http.StatusOK)
	_, _ = response.Write(avatar.Bytes)
}
