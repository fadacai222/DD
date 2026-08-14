package httpapi

import (
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
)

func (s *server) handleAdminWeb(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		methodNotAllowed(response, http.MethodGet, http.MethodHead)
		return
	}
	if s.adminWebRoot == "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if request.URL.Path == "/admin" {
		http.Redirect(response, request, "/admin/", http.StatusPermanentRedirect)
		return
	}

	relative := strings.TrimPrefix(request.URL.Path, "/admin/")
	cleaned := strings.TrimPrefix(path.Clean("/"+relative), "/")
	if cleaned == "." || cleaned == "" {
		cleaned = "index.html"
	}
	candidate, ok := safeAdminWebPath(s.adminWebRoot, cleaned)
	if !ok {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
		setAdminWebHeaders(response, cleaned == "index.html")
		http.ServeFile(response, request, candidate)
		return
	}
	if strings.HasPrefix(cleaned, "assets/") || filepath.Ext(cleaned) != "" {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	indexPath, ok := safeAdminWebPath(s.adminWebRoot, "index.html")
	if !ok {
		writeAPIError(response, http.StatusNotFound, "NOT_FOUND", "Requested resource was not found")
		return
	}
	if info, err := os.Stat(indexPath); err != nil || info.IsDir() {
		writeAPIError(response, http.StatusNotFound, "ADMIN_WEB_UNAVAILABLE", "Administrator web application is not installed")
		return
	}
	setAdminWebHeaders(response, true)
	http.ServeFile(response, request, indexPath)
}

func safeAdminWebPath(root, relative string) (string, bool) {
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return "", false
	}
	candidate := filepath.Join(rootAbs, filepath.FromSlash(relative))
	rel, err := filepath.Rel(rootAbs, candidate)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	return candidate, true
}

func setAdminWebHeaders(response http.ResponseWriter, index bool) {
	response.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	response.Header().Set("X-Frame-Options", "DENY")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.Header().Set("Referrer-Policy", "no-referrer")
	if index {
		response.Header().Set("Cache-Control", "no-store")
	} else {
		response.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	}
}
