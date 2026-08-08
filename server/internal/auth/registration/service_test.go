package registration

import (
	"strings"
	"testing"
)

func TestValidateRegisterInput(t *testing.T) {
	valid := RegisterInput{
		Email:       " User@Example.COM ",
		Code:        "123456",
		Password:    "correct horse battery staple",
		Handle:      " Liang_01 ",
		DisplayName: " 良 ",
		Device: DeviceInput{
			Name:       "My Windows PC",
			Platform:   "windows",
			AppVersion: "0.4.0",
		},
	}

	normalized, err := validateRegisterInput(valid)
	if err != nil {
		t.Fatalf("validateRegisterInput(valid) error = %v", err)
	}
	if normalized.Email != "user@example.com" || normalized.Handle != "liang_01" {
		t.Fatalf("normalized = %#v", normalized)
	}
	if normalized.DisplayName != "良" || normalized.Device.Platform != "WINDOWS" {
		t.Fatalf("normalized display/device = %#v", normalized)
	}

	invalid := []RegisterInput{
		{Email: "bad", Code: "123456", Password: "0123456789", Handle: "valid_01", DisplayName: "User", Device: DeviceInput{Name: "PC", Platform: "windows"}},
		{Email: "user@example.com", Code: "12345", Password: "0123456789", Handle: "valid_01", DisplayName: "User", Device: DeviceInput{Name: "PC", Platform: "windows"}},
		{Email: "user@example.com", Code: "123456", Password: "short", Handle: "valid_01", DisplayName: "User", Device: DeviceInput{Name: "PC", Platform: "windows"}},
		{Email: "user@example.com", Code: "123456", Password: "0123456789", Handle: "ADMIN", DisplayName: "User", Device: DeviceInput{Name: "PC", Platform: "windows"}},
		{Email: "user@example.com", Code: "123456", Password: "0123456789", Handle: "valid_01", DisplayName: "", Device: DeviceInput{Name: "PC", Platform: "windows"}},
		{Email: "user@example.com", Code: "123456", Password: "0123456789", Handle: "valid_01", DisplayName: "User", Device: DeviceInput{Name: "", Platform: "windows"}},
		{Email: "user@example.com", Code: "123456", Password: "0123456789", Handle: "valid_01", DisplayName: "User", Device: DeviceInput{Name: "PC", Platform: "symbian"}},
	}
	for index, input := range invalid {
		if _, err := validateRegisterInput(input); err == nil {
			t.Fatalf("invalid[%d] unexpectedly passed: %#v", index, input)
		}
	}
}

func TestValidateEmailCodeInput(t *testing.T) {
	got, err := validateSendCodeInput(" User@bücher.example ")
	if err != nil {
		t.Fatalf("valid email error = %v", err)
	}
	if got != "user@xn--bcher-kva.example" {
		t.Fatalf("normalized email = %q", got)
	}
	if _, err := validateSendCodeInput("not-an-email"); err == nil {
		t.Fatal("invalid email unexpectedly passed")
	}
}

func TestDisplayAndDeviceLengthLimitsUseCharactersNotBytes(t *testing.T) {
	input := RegisterInput{
		Email:       "user@example.com",
		Code:        "123456",
		Password:    "0123456789",
		Handle:      "valid_01",
		DisplayName: strings.Repeat("良", 80),
		Device:      DeviceInput{Name: strings.Repeat("机", 120), Platform: "android", AppVersion: strings.Repeat("1", 40)},
	}
	if _, err := validateRegisterInput(input); err != nil {
		t.Fatalf("UTF-8 max-length valid input error = %v", err)
	}
	input.DisplayName += "良"
	if _, err := validateRegisterInput(input); err == nil {
		t.Fatal("81-character display name unexpectedly passed")
	}
}
