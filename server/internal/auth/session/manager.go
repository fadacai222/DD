package session

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const (
	minimumSecretBytes = 32
	refreshTokenBytes  = 32
)

type Manager struct {
	secret     []byte
	issuer     string
	accessTTL  time.Duration
	refreshTTL time.Duration
	now        func() time.Time
}

type Config struct {
	Secret     string
	Issuer     string
	AccessTTL  time.Duration
	RefreshTTL time.Duration
	Now        func() time.Time
}

type AccessToken struct {
	Raw       string
	ExpiresAt time.Time
}

type RefreshToken struct {
	Raw       string
	Hash      []byte
	ExpiresAt time.Time
	FamilyID  uuid.UUID
}

type Claims struct {
	DeviceID string `json:"deviceId"`
	jwt.RegisteredClaims
}

func NewManager(config Config) (*Manager, error) {
	if len(config.Secret) < minimumSecretBytes {
		return nil, fmt.Errorf("auth token secret must contain at least %d bytes", minimumSecretBytes)
	}
	issuer := config.Issuer
	if issuer == "" {
		issuer = "dd"
	}
	accessTTL := config.AccessTTL
	if accessTTL <= 0 || accessTTL > time.Hour {
		accessTTL = 15 * time.Minute
	}
	refreshTTL := config.RefreshTTL
	if refreshTTL < time.Hour || refreshTTL > 365*24*time.Hour {
		refreshTTL = 30 * 24 * time.Hour
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Manager{
		secret:     []byte(config.Secret),
		issuer:     issuer,
		accessTTL:  accessTTL,
		refreshTTL: refreshTTL,
		now:        now,
	}, nil
}

func (manager *Manager) NewAccessToken(userID, deviceID uuid.UUID) (AccessToken, error) {
	now := manager.now().UTC()
	expiresAt := now.Add(manager.accessTTL)
	claims := Claims{
		DeviceID: deviceID.String(),
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    manager.issuer,
			Subject:   userID.String(),
			Audience:  jwt.ClaimStrings{"dd-api"},
			ExpiresAt: jwt.NewNumericDate(expiresAt),
			IssuedAt:  jwt.NewNumericDate(now),
			NotBefore: jwt.NewNumericDate(now),
			ID:        uuid.NewString(),
		},
	}
	raw, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(manager.secret)
	if err != nil {
		return AccessToken{}, fmt.Errorf("sign access token: %w", err)
	}
	return AccessToken{Raw: raw, ExpiresAt: expiresAt}, nil
}

func (manager *Manager) NewRefreshToken(familyID uuid.UUID) (RefreshToken, error) {
	if familyID == uuid.Nil {
		familyID = uuid.New()
	}
	buffer := make([]byte, refreshTokenBytes)
	if _, err := rand.Read(buffer); err != nil {
		return RefreshToken{}, fmt.Errorf("generate refresh token: %w", err)
	}
	raw := base64.RawURLEncoding.EncodeToString(buffer)
	hash := sha256.Sum256([]byte(raw))
	return RefreshToken{
		Raw:       raw,
		Hash:      append([]byte(nil), hash[:]...),
		ExpiresAt: manager.now().UTC().Add(manager.refreshTTL),
		FamilyID:  familyID,
	}, nil
}

func HashRefreshToken(raw string) ([]byte, error) {
	if raw == "" {
		return nil, errors.New("refresh token is required")
	}
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil || len(decoded) != refreshTokenBytes {
		return nil, errors.New("refresh token is malformed")
	}
	hash := sha256.Sum256([]byte(raw))
	return append([]byte(nil), hash[:]...), nil
}

func (manager *Manager) ParseAccessToken(raw string) (Claims, error) {
	claims := Claims{}
	token, err := jwt.ParseWithClaims(
		raw,
		&claims,
		func(token *jwt.Token) (any, error) {
			if token.Method != jwt.SigningMethodHS256 {
				return nil, errors.New("unexpected access token signing method")
			}
			return manager.secret, nil
		},
		jwt.WithIssuer(manager.issuer),
		jwt.WithAudience("dd-api"),
		jwt.WithExpirationRequired(),
		jwt.WithTimeFunc(func() time.Time { return manager.now().UTC() }),
	)
	if err != nil || !token.Valid {
		return Claims{}, errors.New("access token is invalid")
	}
	if _, err := uuid.Parse(claims.Subject); err != nil {
		return Claims{}, errors.New("access token subject is invalid")
	}
	if _, err := uuid.Parse(claims.DeviceID); err != nil {
		return Claims{}, errors.New("access token device is invalid")
	}
	return claims, nil
}
