package registration

import (
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/identity"
	"golang.org/x/text/unicode/norm"
)

const (
	verificationCodeLength = 6
	maxDisplayNameRunes    = 80
	maxDeviceNameRunes     = 120
	maxAppVersionRunes     = 40
)

var allowedPlatforms = map[string]struct{}{
	"WINDOWS": {},
	"MACOS":   {},
	"LINUX":   {},
	"ANDROID": {},
	"IOS":     {},
	"WEB":     {},
}

type DeviceInput struct {
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"appVersion,omitempty"`
}

type RegisterInput struct {
	Email       string      `json:"email"`
	Code        string      `json:"code"`
	Password    string      `json:"password"`
	Handle      string      `json:"handle"`
	DisplayName string      `json:"displayName"`
	InviteCode  *string     `json:"inviteCode,omitempty"`
	Device      DeviceInput `json:"device"`
}

func ValidateSendCodeInput(rawEmail string) (string, error) {
	email, err := identity.NormalizeEmail(rawEmail)
	if err != nil {
		return "", fmt.Errorf("invalid email: %w", err)
	}
	return email, nil
}

func ValidateRegisterInput(input RegisterInput) (RegisterInput, error) {
	email, err := ValidateSendCodeInput(input.Email)
	if err != nil {
		return RegisterInput{}, err
	}
	if !isVerificationCode(input.Code) {
		return RegisterInput{}, fmt.Errorf("verification code must contain exactly %d digits", verificationCodeLength)
	}
	if err := password.ValidatePolicy(input.Password); err != nil {
		return RegisterInput{}, err
	}
	handle, err := identity.NormalizeHandle(input.Handle)
	if err != nil {
		return RegisterInput{}, fmt.Errorf("invalid handle: %w", err)
	}

	displayName, err := normalizeRequiredText(input.DisplayName, maxDisplayNameRunes, "display name")
	if err != nil {
		return RegisterInput{}, err
	}
	device, err := ValidateDeviceInput(input.Device)
	if err != nil {
		return RegisterInput{}, err
	}

	input.Email = email
	input.Handle = handle
	input.DisplayName = displayName
	input.Device = device
	if input.InviteCode != nil {
		trimmed := strings.TrimSpace(norm.NFKC.String(*input.InviteCode))
		input.InviteCode = &trimmed
	}
	return input, nil
}

func ValidateDeviceInput(input DeviceInput) (DeviceInput, error) {
	deviceName, err := normalizeRequiredText(input.Name, maxDeviceNameRunes, "device name")
	if err != nil {
		return DeviceInput{}, err
	}
	appVersion := strings.TrimSpace(norm.NFKC.String(input.AppVersion))
	if utf8.RuneCountInString(appVersion) > maxAppVersionRunes {
		return DeviceInput{}, fmt.Errorf("app version exceeds %d characters", maxAppVersionRunes)
	}
	platform := strings.ToUpper(strings.TrimSpace(input.Platform))
	if _, ok := allowedPlatforms[platform]; !ok {
		return DeviceInput{}, errors.New("unsupported device platform")
	}
	return DeviceInput{Name: deviceName, Platform: platform, AppVersion: appVersion}, nil
}

func validateSendCodeInput(rawEmail string) (string, error) { return ValidateSendCodeInput(rawEmail) }
func validateRegisterInput(input RegisterInput) (RegisterInput, error) {
	return ValidateRegisterInput(input)
}

func normalizeRequiredText(raw string, maxRunes int, field string) (string, error) {
	value := strings.TrimSpace(norm.NFKC.String(raw))
	length := utf8.RuneCountInString(value)
	if length == 0 {
		return "", fmt.Errorf("%s is required", field)
	}
	if length > maxRunes {
		return "", fmt.Errorf("%s exceeds %d characters", field, maxRunes)
	}
	return value, nil
}

func isVerificationCode(value string) bool {
	if len(value) != verificationCodeLength {
		return false
	}
	for index := 0; index < len(value); index++ {
		if value[index] < '0' || value[index] > '9' {
			return false
		}
	}
	return true
}
