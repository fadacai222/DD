package httpapi

import (
	"net/http"
	"path"
	"strings"
)

func corsMiddleware(allowedOrigins []string, next http.Handler) http.Handler {
	patterns := append([]string(nil), allowedOrigins...)
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		origin := strings.TrimSpace(request.Header.Get("Origin"))
		if origin != "" {
			if !matchesOrigin(patterns, origin) {
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
