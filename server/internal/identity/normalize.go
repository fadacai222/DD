package identity

import (
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/idna"
	"golang.org/x/text/unicode/norm"
)

var reservedHandles = map[string]struct{}{
	"admin": {}, "administrator": {}, "api": {}, "dd": {}, "help": {},
	"moderator": {}, "null": {}, "root": {}, "security": {}, "support": {},
	"system": {}, "undefined": {}, "webmaster": {},
}

func NormalizeHandle(raw string) (string, error) {
	value := strings.ToLower(strings.TrimSpace(norm.NFKC.String(raw)))
	if len(value) < 3 || len(value) > 32 || utf8.RuneCountInString(value) != len(value) {
		return "", errors.New("handle must contain 3-32 ASCII characters")
	}
	if value[0] < 'a' || value[0] > 'z' {
		return "", errors.New("handle must start with an ASCII letter")
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '_' {
			continue
		}
		return "", errors.New("handle may only contain lowercase letters, digits, and underscore")
	}
	if _, reserved := reservedHandles[value]; reserved {
		return "", errors.New("handle is reserved")
	}
	return value, nil
}

func NormalizeEmail(raw string) (string, error) {
	value := strings.TrimSpace(norm.NFKC.String(raw))
	if strings.Count(value, "@") != 1 {
		return "", errors.New("email must contain exactly one @")
	}
	local, domain, _ := strings.Cut(value, "@")
	if local == "" || domain == "" {
		return "", errors.New("email local part and domain are required")
	}
	if len(local) > 64 || !isASCIILocalPart(local) {
		return "", errors.New("email local part is unsupported or invalid")
	}
	if local[0] == '.' || local[len(local)-1] == '.' || strings.Contains(local, "..") {
		return "", errors.New("email local part has invalid dot placement")
	}

	asciiDomain, err := idna.Lookup.ToASCII(domain)
	if err != nil {
		return "", fmt.Errorf("email domain is invalid: %w", err)
	}
	asciiDomain = strings.ToLower(strings.TrimSpace(asciiDomain))
	if err := validateDomain(asciiDomain); err != nil {
		return "", err
	}

	normalized := strings.ToLower(local) + "@" + asciiDomain
	if len(normalized) > 254 {
		return "", errors.New("email exceeds 254 bytes after normalization")
	}
	return normalized, nil
}

func isASCIILocalPart(value string) bool {
	for index := 0; index < len(value); index++ {
		character := value[index]
		switch {
		case character >= 'a' && character <= 'z':
		case character >= 'A' && character <= 'Z':
		case character >= '0' && character <= '9':
		case strings.ContainsRune(".!#$%&'*+/=?^_`{|}~-", rune(character)):
		default:
			return false
		}
	}
	return true
}

func validateDomain(domain string) error {
	if domain == "" || len(domain) > 253 || strings.HasSuffix(domain, ".") {
		return errors.New("email domain is invalid")
	}
	labels := strings.Split(domain, ".")
	if len(labels) < 2 {
		return errors.New("email domain must contain a dot")
	}
	for _, label := range labels {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return errors.New("email domain label is invalid")
		}
		for _, character := range label {
			if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' {
				continue
			}
			return errors.New("email domain contains invalid characters")
		}
	}
	return nil
}
