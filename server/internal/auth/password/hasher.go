package password

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

const (
	minMemoryKiB     uint32 = 8 * 1024
	maxMemoryKiB     uint32 = 1024 * 1024
	maxIterations    uint32 = 10
	maxParallelism   uint8  = 32
	maxPasswordBytes        = 1024
)

var ErrInvalidHash = errors.New("invalid argon2id password hash")

type Params struct {
	MemoryKiB   uint32
	Iterations  uint32
	Parallelism uint8
	SaltLength  uint32
	KeyLength   uint32
}

func DefaultParams() Params {
	return Params{
		MemoryKiB:   64 * 1024,
		Iterations:  3,
		Parallelism: 4,
		SaltLength:  16,
		KeyLength:   32,
	}
}

type VerifyResult struct {
	Match       bool
	NeedsRehash bool
}

type Hasher struct {
	params Params
}

func NewHasher(params Params) (*Hasher, error) {
	if err := validateParams(params); err != nil {
		return nil, err
	}
	return &Hasher{params: params}, nil
}

func NewDefaultHasher() *Hasher {
	hasher, err := NewHasher(DefaultParams())
	if err != nil {
		panic(err)
	}
	return hasher
}

func (hasher *Hasher) Hash(plaintext string) (string, error) {
	if err := validatePlaintext(plaintext); err != nil {
		return "", err
	}

	salt := make([]byte, hasher.params.SaltLength)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("generate password salt: %w", err)
	}
	key := argon2.IDKey(
		[]byte(plaintext),
		salt,
		hasher.params.Iterations,
		hasher.params.MemoryKiB,
		hasher.params.Parallelism,
		hasher.params.KeyLength,
	)
	return encodePHC(hasher.params, salt, key), nil
}

func (hasher *Hasher) Verify(encoded, plaintext string) (VerifyResult, error) {
	if err := validatePlaintext(plaintext); err != nil {
		return VerifyResult{}, err
	}
	parsed, err := parsePHC(encoded)
	if err != nil {
		return VerifyResult{}, err
	}
	actual := argon2.IDKey(
		[]byte(plaintext),
		parsed.salt,
		parsed.params.Iterations,
		parsed.params.MemoryKiB,
		parsed.params.Parallelism,
		uint32(len(parsed.key)),
	)
	match := subtle.ConstantTimeCompare(actual, parsed.key) == 1
	return VerifyResult{
		Match:       match,
		NeedsRehash: match && !sameParams(hasher.params, parsed.params),
	}, nil
}

type parsedHash struct {
	params Params
	salt   []byte
	key    []byte
}

func encodePHC(params Params, salt, key []byte) string {
	return fmt.Sprintf(
		"$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version,
		params.MemoryKiB,
		params.Iterations,
		params.Parallelism,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	)
}

func parsePHC(encoded string) (parsedHash, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" {
		return parsedHash{}, ErrInvalidHash
	}
	if parts[2] != "v="+strconv.Itoa(argon2.Version) {
		return parsedHash{}, ErrInvalidHash
	}

	parameterParts := strings.Split(parts[3], ",")
	if len(parameterParts) != 3 {
		return parsedHash{}, ErrInvalidHash
	}
	values := make(map[string]uint64, 3)
	for _, part := range parameterParts {
		key, raw, ok := strings.Cut(part, "=")
		if !ok || (key != "m" && key != "t" && key != "p") {
			return parsedHash{}, ErrInvalidHash
		}
		if _, duplicate := values[key]; duplicate {
			return parsedHash{}, ErrInvalidHash
		}
		value, err := strconv.ParseUint(raw, 10, 32)
		if err != nil {
			return parsedHash{}, ErrInvalidHash
		}
		values[key] = value
	}
	if values["p"] > 255 {
		return parsedHash{}, ErrInvalidHash
	}

	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return parsedHash{}, ErrInvalidHash
	}
	key, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return parsedHash{}, ErrInvalidHash
	}
	params := Params{
		MemoryKiB:   uint32(values["m"]),
		Iterations:  uint32(values["t"]),
		Parallelism: uint8(values["p"]),
		SaltLength:  uint32(len(salt)),
		KeyLength:   uint32(len(key)),
	}
	if err := validateParams(params); err != nil {
		return parsedHash{}, ErrInvalidHash
	}
	return parsedHash{params: params, salt: salt, key: key}, nil
}

func validateParams(params Params) error {
	if params.MemoryKiB < minMemoryKiB || params.MemoryKiB > maxMemoryKiB {
		return fmt.Errorf("argon2id memory must be between %d and %d KiB", minMemoryKiB, maxMemoryKiB)
	}
	if params.Iterations < 1 || params.Iterations > maxIterations {
		return fmt.Errorf("argon2id iterations must be between 1 and %d", maxIterations)
	}
	if params.Parallelism < 1 || params.Parallelism > maxParallelism {
		return fmt.Errorf("argon2id parallelism must be between 1 and %d", maxParallelism)
	}
	if params.SaltLength < 16 || params.SaltLength > 64 {
		return errors.New("argon2id salt length must be between 16 and 64 bytes")
	}
	if params.KeyLength < 16 || params.KeyLength > 64 {
		return errors.New("argon2id key length must be between 16 and 64 bytes")
	}
	return nil
}

func validatePlaintext(plaintext string) error {
	length := len([]byte(plaintext))
	if length == 0 {
		return errors.New("password must not be empty")
	}
	if length > maxPasswordBytes {
		return fmt.Errorf("password exceeds %d bytes", maxPasswordBytes)
	}
	return nil
}

func sameParams(left, right Params) bool {
	return left.MemoryKiB == right.MemoryKiB &&
		left.Iterations == right.Iterations &&
		left.Parallelism == right.Parallelism &&
		left.SaltLength == right.SaltLength &&
		left.KeyLength == right.KeyLength
}
