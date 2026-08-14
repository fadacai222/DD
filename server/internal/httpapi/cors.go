package httpapi

import (
	"net/http"
	"net/url"
	"path"
	"strings"
)

func corsMiddleware(allowedOrigins []string, publicBaseURL string, next http.Handler) http.Handler {
	patterns := append([]string(nil), allowedOrigins...)
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		origin := strings.TrimSpace(request.Header.Get("Origin"))
		if origin != "" {
			if !matchesPublicOrigin(publicBaseURL, origin) && !isSameOriginRequest(request, origin) && !matchesOrigin(patterns, origin) {
				writeAPIError(response, http.StatusForbidden, "ORIGIN_NOT_ALLOWED", "Origin is not allowed")
				return
			}
			response.Header().Set("Access-Control-Allow-Origin", origin)
			response.Header().Set("Access-Control-Allow-Credentials", "true")
			response.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			response.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-DD-Admin-CSRF")
			response.Header().Set("Access-Control-Max-Age", "600")
			response.Header().Add("Vary", "Origin")
			if request.Method == http.MethodOptions {
				response.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(response, request)
	})
}

func matchesPublicOrigin(publicBaseURL, origin string) bool {
	publicURL, err := url.Parse(strings.TrimSpace(publicBaseURL))
	if err != nil || publicURL.Scheme == "" || publicURL.Host == "" {
		return false
	}
	originURL, err := url.Parse(origin)
	if err != nil || originURL.Scheme == "" || originURL.Host == "" {
		return false
	}
	return strings.EqualFold(publicURL.Scheme, originURL.Scheme) && strings.EqualFold(publicURL.Host, originURL.Host)
}

func isSameOriginRequest(request *http.Request, origin string) bool {
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return false
	}
	if !strings.EqualFold(parsed.Host, request.Host) {
		return false
	}

	scheme := "http"
	if forwarded := strings.TrimSpace(strings.Split(request.Header.Get("X-Forwarded-Proto"), ",")[0]); forwarded == "http" || forwarded == "https" {
		scheme = forwarded
	} else if request.TLS != nil {
		scheme = "https"
	}
	return strings.EqualFold(parsed.Scheme, scheme)
}

func matchesOrigin(patterns []string, origin string) bool {
	for _, rawPattern := range patterns {
		pattern := strings.TrimSpace(rawPattern)
		if pattern == "" {
			continue
		}
		matched, err := path.Match(pattern, origin)
		if err == nil && matched {
			return true
		}
	}
	return false
}
