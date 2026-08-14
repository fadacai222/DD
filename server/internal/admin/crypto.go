package admin

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

const (
	sessionTokenBytes   = 32
	challengeTokenBytes = 32
	recoveryCodeCount   = 10
	recoveryCodeBytes   = 8
)

type secretBox struct {
	aead cipher.AEAD
	key  []byte
	aad  []byte
}

func newSecretBox(masterSecret string) (*secretBox, error) {
	return newPurposeSecretBox(masterSecret, "dd-admin-mfa-v1")
}

func newPurposeSecretBox(masterSecret, purpose string) (*secretBox, error) {
	if len(masterSecret) < 32 {
		return nil, errors.New("admin secret must contain at least 32 bytes")
	}
	purpose = strings.TrimSpace(purpose)
	if purpose == "" {
		return nil, errors.New("admin secret purpose is required")
	}
	key := sha256.Sum256([]byte(purpose + "\x00" + masterSecret))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, fmt.Errorf("initialize admin secret cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("initialize admin secret gcm: %w", err)
	}
	return &secretBox{aead: aead, key: append([]byte(nil), key[:]...), aad: []byte(purpose)}, nil
}

func (box *secretBox) encrypt(plaintext []byte) ([]byte, error) {
	nonce := make([]byte, box.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("generate admin secret nonce: %w", err)
	}
	sealed := box.aead.Seal(nil, nonce, plaintext, box.aad)
	return append(nonce, sealed...), nil
}

func (box *secretBox) decrypt(ciphertext []byte) ([]byte, error) {
	if len(ciphertext) <= box.aead.NonceSize() {
		return nil, errors.New("admin secret ciphertext is invalid")
	}
	nonce := ciphertext[:box.aead.NonceSize()]
	sealed := ciphertext[box.aead.NonceSize():]
	plaintext, err := box.aead.Open(nil, nonce, sealed, box.aad)
	if err != nil {
		return nil, errors.New("admin secret ciphertext is invalid")
	}
	return plaintext, nil
}

func (box *secretBox) csrfToken(rawSessionToken string) string {
	mac := hmac.New(sha256.New, box.key)
	_, _ = mac.Write([]byte("csrf\x00" + rawSessionToken))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (box *secretBox) verifyCSRF(rawSessionToken, provided string) bool {
	provided = strings.TrimSpace(provided)
	if provided == "" {
		return false
	}
	expected := box.csrfToken(rawSessionToken)
	return hmac.Equal([]byte(expected), []byte(provided))
}

func newOpaqueToken(prefix string, size int) (raw string, hash []byte, err error) {
	buffer := make([]byte, size)
	if _, err := rand.Read(buffer); err != nil {
		return "", nil, fmt.Errorf("generate admin token: %w", err)
	}
	raw = prefix + base64.RawURLEncoding.EncodeToString(buffer)
	digest := sha256.Sum256([]byte(raw))
	return raw, append([]byte(nil), digest[:]...), nil
}

func hashOpaqueToken(raw, prefix string, size int) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, prefix) {
		return nil, errors.New("admin token is malformed")
	}
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(raw, prefix))
	if err != nil || len(decoded) != size {
		return nil, errors.New("admin token is malformed")
	}
	digest := sha256.Sum256([]byte(raw))
	return append([]byte(nil), digest[:]...), nil
}

func newRecoveryCodes() ([]string, [][]byte, error) {
	codes := make([]string, 0, recoveryCodeCount)
	hashes := make([][]byte, 0, recoveryCodeCount)
	encoder := base32.StdEncoding.WithPadding(base32.NoPadding)
	for range recoveryCodeCount {
		buffer := make([]byte, recoveryCodeBytes)
		if _, err := rand.Read(buffer); err != nil {
			return nil, nil, fmt.Errorf("generate recovery code: %w", err)
		}
		raw := encoder.EncodeToString(buffer)
		formatted := raw[:4] + "-" + raw[4:8] + "-" + raw[8:]
		codes = append(codes, formatted)
		hashes = append(hashes, hashRecoveryCode(formatted))
	}
	return codes, hashes, nil
}

func hashRecoveryCode(raw string) []byte {
	normalized := strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(raw), "-", ""))
	digest := sha256.Sum256([]byte(normalized))
	return append([]byte(nil), digest[:]...)
}
