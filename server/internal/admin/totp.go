package admin

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	totpPeriodSeconds = int64(30)
	totpDigits        = 6
)

func generateTOTPSecret() (string, error) {
	buffer := make([]byte, 20)
	if _, err := rand.Read(buffer); err != nil {
		return "", fmt.Errorf("generate totp secret: %w", err)
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(buffer), nil
}

func totpURI(email, secret string) string {
	issuer := "DD Admin"
	label := issuer + ":" + email
	query := url.Values{}
	query.Set("secret", secret)
	query.Set("issuer", issuer)
	query.Set("algorithm", "SHA1")
	query.Set("digits", strconv.Itoa(totpDigits))
	query.Set("period", strconv.FormatInt(totpPeriodSeconds, 10))
	return "otpauth://totp/" + url.PathEscape(label) + "?" + query.Encode()
}

func verifyTOTP(secret, code string, now time.Time) (int64, bool) {
	code = strings.TrimSpace(code)
	if len(code) != totpDigits {
		return 0, false
	}
	for _, character := range code {
		if character < '0' || character > '9' {
			return 0, false
		}
	}
	counter := now.UTC().Unix() / totpPeriodSeconds
	for offset := int64(-1); offset <= 1; offset++ {
		candidateCounter := counter + offset
		if candidateCounter < 0 {
			continue
		}
		candidate, err := totpAtCounter(secret, candidateCounter)
		if err == nil && hmac.Equal([]byte(candidate), []byte(code)) {
			return candidateCounter, true
		}
	}
	return 0, false
}

func totpAtCounter(secret string, counter int64) (string, error) {
	secret = strings.ToUpper(strings.TrimSpace(secret))
	decoded, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	if err != nil || len(decoded) < 16 {
		return "", errors.New("totp secret is invalid")
	}
	message := make([]byte, 8)
	binary.BigEndian.PutUint64(message, uint64(counter))
	mac := hmac.New(sha1.New, decoded)
	_, _ = mac.Write(message)
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	binaryCode := (uint32(sum[offset])&0x7f)<<24 |
		(uint32(sum[offset+1])&0xff)<<16 |
		(uint32(sum[offset+2])&0xff)<<8 |
		(uint32(sum[offset+3]) & 0xff)
	value := binaryCode % 1000000
	return fmt.Sprintf("%06d", value), nil
}
