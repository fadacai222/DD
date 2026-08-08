package emailcode

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"math/big"
)

type Purpose string

const (
	PurposeRegister      Purpose = "REGISTER"
	PurposePasswordReset Purpose = "PASSWORD_RESET"
	PurposeChangeEmail   Purpose = "CHANGE_EMAIL"
)

type Codec struct {
	pepper []byte
}

func NewCodec(pepper []byte) (*Codec, error) {
	if len(pepper) < 32 {
		return nil, errors.New("email code pepper must contain at least 32 bytes")
	}
	copied := append([]byte(nil), pepper...)
	return &Codec{pepper: copied}, nil
}

func (codec *Codec) Generate() (string, error) {
	value, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", fmt.Errorf("generate email verification code: %w", err)
	}
	return fmt.Sprintf("%06d", value.Int64()), nil
}

func (codec *Codec) Hash(email string, purpose Purpose, code string) []byte {
	mac := hmac.New(sha256.New, codec.pepper)
	_, _ = mac.Write([]byte(purpose))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(email))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(code))
	return mac.Sum(nil)
}

func (codec *Codec) HashMetadata(scope, value string) []byte {
	mac := hmac.New(sha256.New, codec.pepper)
	_, _ = mac.Write([]byte("metadata"))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(scope))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(value))
	return mac.Sum(nil)
}

func (codec *Codec) Verify(expected []byte, email string, purpose Purpose, code string) bool {
	if len(expected) != sha256.Size {
		return false
	}
	actual := codec.Hash(email, purpose, code)
	return subtle.ConstantTimeCompare(expected, actual) == 1
}
