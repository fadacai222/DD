package push

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

const pushAvatarCapabilityVersion = "dd-push-avatar-v1"

func SignedAvatarURL(publicBaseURL, secret string, userID uuid.UUID, expiresAt time.Time) string {
	secret = strings.TrimSpace(secret)
	if secret == "" || userID == uuid.Nil {
		return ""
	}
	base, err := url.Parse(strings.TrimSpace(publicBaseURL))
	if err != nil || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" || (base.Path != "" && base.Path != "/") {
		return ""
	}
	if base.Scheme != "https" && !(base.Scheme == "http" && isPrivateDevelopmentHost(base.Hostname())) {
		return ""
	}
	expiresAt = expiresAt.UTC().Truncate(time.Second)
	signature := avatarCapabilitySignature(secret, userID, expiresAt)
	base.Path = "/push-assets/avatars/" + userID.String()
	query := base.Query()
	query.Set("expires", expiresAt.Format(time.RFC3339))
	query.Set("sig", signature)
	base.RawQuery = query.Encode()
	return base.String()
}

func VerifyAvatarCapability(secret string, userID uuid.UUID, expiresAt time.Time, signature string, now time.Time) bool {
	secret = strings.TrimSpace(secret)
	signature = strings.TrimSpace(signature)
	if secret == "" || userID == uuid.Nil || signature == "" {
		return false
	}
	expiresAt = expiresAt.UTC().Truncate(time.Second)
	now = now.UTC()
	if !expiresAt.After(now) || expiresAt.After(now.Add(48*time.Hour)) {
		return false
	}
	expected, err := hex.DecodeString(avatarCapabilitySignature(secret, userID, expiresAt))
	if err != nil {
		return false
	}
	provided, err := hex.DecodeString(signature)
	if err != nil || len(provided) != len(expected) {
		return false
	}
	return hmac.Equal(provided, expected)
}

func isPrivateDevelopmentHost(host string) bool {
	host = strings.TrimSpace(strings.Trim(host, "[]"))
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate())
}

func avatarCapabilitySignature(secret string, userID uuid.UUID, expiresAt time.Time) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(pushAvatarCapabilityVersion))
	_, _ = mac.Write([]byte{'\n'})
	_, _ = mac.Write([]byte(userID.String()))
	_, _ = mac.Write([]byte{'\n'})
	_, _ = mac.Write([]byte(strconv.FormatInt(expiresAt.Unix(), 10)))
	return hex.EncodeToString(mac.Sum(nil))
}
