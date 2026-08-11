package httpapi

import (
	"net"
	"net/url"
	"strings"
	"testing"
)

func TestParseSafePreviewURLRejectsPrivateAndUnsafeTargets(t *testing.T) {
	t.Parallel()
	for _, raw := range []string{
		"file:///etc/passwd",
		"http://127.0.0.1/admin",
		"http://169.254.169.254/latest/meta-data",
		"http://10.0.0.8/private",
		"http://[::1]/",
		"https://example.com:8443/private",
		"https://user:pass@example.com/",
	} {
		raw := raw
		t.Run(raw, func(t *testing.T) {
			t.Parallel()
			if _, err := parseSafePreviewURL(raw); err == nil {
				t.Fatalf("parseSafePreviewURL(%q) unexpectedly succeeded", raw)
			}
		})
	}

	parsed, err := parseSafePreviewURL("https://example.com/path?q=1#fragment")
	if err != nil {
		t.Fatalf("public URL rejected: %v", err)
	}
	if parsed.Fragment != "" {
		t.Fatalf("fragment=%q want empty", parsed.Fragment)
	}
}

func TestBlockedPreviewIPIncludesMetadataAndCarrierGradeRanges(t *testing.T) {
	t.Parallel()
	for _, raw := range []string{
		"127.0.0.1",
		"10.2.3.4",
		"169.254.169.254",
		"100.64.0.1",
		"192.0.2.1",
		"198.18.0.1",
		"::1",
		"fc00::1",
	} {
		if !isBlockedPreviewIP(net.ParseIP(raw)) {
			t.Fatalf("expected %s to be blocked", raw)
		}
	}
	if isBlockedPreviewIP(net.ParseIP("8.8.8.8")) {
		t.Fatal("public address 8.8.8.8 must remain previewable")
	}
}

func TestParseLinkPreviewHTMLPrefersOpenGraphMetadata(t *testing.T) {
	t.Parallel()
	finalURL, err := url.Parse("https://example.com/articles/1")
	if err != nil {
		t.Fatal(err)
	}
	preview, err := parseLinkPreviewHTML(finalURL, strings.NewReader(`
		<html>
		<head>
			<title>Fallback title</title>
			<meta property="og:site_name" content="Example News">
			<meta property="og:title" content="  Main   headline  ">
			<meta name="description" content=" A useful   summary. ">
		</head>
		</html>`))
	if err != nil {
		t.Fatalf("parse preview: %v", err)
	}
	if preview.SiteName != "Example News" {
		t.Fatalf("siteName=%q", preview.SiteName)
	}
	if preview.Title != "Main headline" {
		t.Fatalf("title=%q", preview.Title)
	}
	if preview.Description != "A useful summary." {
		t.Fatalf("description=%q", preview.Description)
	}
	if preview.URL != finalURL.String() {
		t.Fatalf("url=%q", preview.URL)
	}
}
