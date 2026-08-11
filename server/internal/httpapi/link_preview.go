package httpapi

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode"

	"golang.org/x/net/html"
)

const (
	linkPreviewTimeout = 5 * time.Second
	linkPreviewMaxHTML = 512 * 1024
)

var (
	errLinkPreviewInvalid = errors.New("invalid link preview url")
	errLinkPreviewBlocked = errors.New("link preview target is blocked")
)

type linkPreviewData struct {
	URL         string `json:"url"`
	SiteName    string `json:"siteName"`
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
}

func (s *server) handleLinkPreview(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		response.Header().Set("Allow", http.MethodGet)
		writeAPIError(response, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Method not allowed")
		return
	}
	if _, ok := s.requirePrincipal(response, request); !ok {
		return
	}

	target, err := parseSafePreviewURL(request.URL.Query().Get("url"))
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_LINK", "Only public HTTP/HTTPS links can be previewed")
		return
	}

	ctx, cancel := context.WithTimeout(request.Context(), linkPreviewTimeout)
	defer cancel()
	preview, err := fetchLinkPreview(ctx, target)
	if err != nil {
		if errors.Is(err, errLinkPreviewInvalid) || errors.Is(err, errLinkPreviewBlocked) {
			writeAPIError(response, http.StatusBadRequest, "INVALID_LINK", "Only public HTTP/HTTPS links can be previewed")
			return
		}
		writeAPIError(response, http.StatusBadGateway, "LINK_PREVIEW_UNAVAILABLE", "Link preview is temporarily unavailable")
		return
	}
	writeSuccess(response, http.StatusOK, preview)
}

func parseSafePreviewURL(raw string) (*url.URL, error) {
	if len(raw) == 0 || len(raw) > 4096 {
		return nil, errLinkPreviewInvalid
	}
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.User != nil || parsed.Hostname() == "" {
		return nil, errLinkPreviewInvalid
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errLinkPreviewInvalid
	}
	if parsed.Fragment != "" {
		parsed.Fragment = ""
	}
	if port := parsed.Port(); port != "" && port != "80" && port != "443" {
		return nil, errLinkPreviewBlocked
	}
	if ip := net.ParseIP(parsed.Hostname()); ip != nil && isBlockedPreviewIP(ip) {
		return nil, errLinkPreviewBlocked
	}
	return parsed, nil
}

func fetchLinkPreview(ctx context.Context, target *url.URL) (linkPreviewData, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DisableKeepAlives = true
	transport.DialContext = safePreviewDialContext
	client := &http.Client{
		Transport: transport,
		Timeout:   linkPreviewTimeout,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			_, err := parseSafePreviewURL(request.URL.String())
			return err
		},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return linkPreviewData{}, errLinkPreviewInvalid
	}
	req.Header.Set("Accept", "text/html,application/xhtml+xml;q=0.9")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.6")
	req.Header.Set("User-Agent", "DD-LinkPreview/1.0")

	resp, err := client.Do(req)
	if err != nil {
		return linkPreviewData{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		return linkPreviewData{}, fmt.Errorf("preview upstream returned %d", resp.StatusCode)
	}
	contentType := strings.ToLower(resp.Header.Get("Content-Type"))
	if contentType != "" && !strings.Contains(contentType, "text/html") && !strings.Contains(contentType, "application/xhtml+xml") {
		return linkPreviewData{}, errors.New("preview target is not html")
	}

	limited := io.LimitReader(resp.Body, linkPreviewMaxHTML+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return linkPreviewData{}, err
	}
	if len(body) > linkPreviewMaxHTML {
		return linkPreviewData{}, errors.New("preview html too large")
	}

	preview, err := parseLinkPreviewHTML(resp.Request.URL, strings.NewReader(string(body)))
	if err != nil {
		return linkPreviewData{}, err
	}
	return preview, nil
}

func safePreviewDialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, errLinkPreviewInvalid
	}
	ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
	if err != nil {
		return nil, fmt.Errorf("resolve preview host: %w", err)
	}
	if len(ips) == 0 {
		return nil, errors.New("preview host resolved without addresses")
	}
	for _, ip := range ips {
		if isBlockedPreviewIP(ip) {
			return nil, errLinkPreviewBlocked
		}
	}
	dialer := &net.Dialer{Timeout: 3 * time.Second}
	var lastErr error
	for _, ip := range ips {
		conn, dialErr := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		if dialErr == nil {
			return conn, nil
		}
		lastErr = dialErr
	}
	return nil, lastErr
}

func isBlockedPreviewIP(ip net.IP) bool {
	if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast() {
		return true
	}
	blockedCIDRs := [...]string{
		"0.0.0.0/8",
		"100.64.0.0/10",
		"192.0.0.0/24",
		"192.0.2.0/24",
		"198.18.0.0/15",
		"198.51.100.0/24",
		"203.0.113.0/24",
		"224.0.0.0/4",
		"240.0.0.0/4",
		"2001:db8::/32",
	}
	for _, raw := range blockedCIDRs {
		_, network, err := net.ParseCIDR(raw)
		if err == nil && network.Contains(ip) {
			return true
		}
	}
	return false
}

func parseLinkPreviewHTML(finalURL *url.URL, reader io.Reader) (linkPreviewData, error) {
	doc, err := html.Parse(reader)
	if err != nil {
		return linkPreviewData{}, err
	}
	meta := make(map[string]string)
	var title string
	var walk func(*html.Node)
	walk = func(node *html.Node) {
		if node.Type == html.ElementNode {
			switch strings.ToLower(node.Data) {
			case "title":
				if title == "" && node.FirstChild != nil {
					title = cleanPreviewText(node.FirstChild.Data, 160)
				}
			case "meta":
				var key, content string
				for _, attr := range node.Attr {
					switch strings.ToLower(attr.Key) {
					case "property", "name":
						if key == "" {
							key = strings.ToLower(strings.TrimSpace(attr.Val))
						}
					case "content":
						content = attr.Val
					}
				}
				if key != "" && content != "" && meta[key] == "" {
					meta[key] = content
				}
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(doc)

	previewTitle := firstPreviewValue(meta["og:title"], meta["twitter:title"], title)
	if previewTitle == "" {
		previewTitle = finalURL.Hostname()
	}
	siteName := cleanPreviewText(firstPreviewValue(meta["og:site_name"], finalURL.Hostname()), 80)
	description := cleanPreviewText(firstPreviewValue(meta["og:description"], meta["twitter:description"], meta["description"]), 320)
	return linkPreviewData{
		URL:         finalURL.String(),
		SiteName:    siteName,
		Title:       cleanPreviewText(previewTitle, 160),
		Description: description,
	}, nil
}

func firstPreviewValue(values ...string) string {
	for _, value := range values {
		if cleaned := strings.TrimSpace(value); cleaned != "" {
			return cleaned
		}
	}
	return ""
}

func cleanPreviewText(value string, maxRunes int) string {
	fields := strings.FieldsFunc(value, unicode.IsSpace)
	cleaned := strings.Join(fields, " ")
	runes := []rune(cleaned)
	if len(runes) <= maxRunes {
		return cleaned
	}
	return string(runes[:maxRunes]) + "…"
}
