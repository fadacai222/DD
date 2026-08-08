package password

import (
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

const (
	minimumPasswordRunes = 10
	maximumPasswordRunes = 256
)

// ValidatePolicy enforces the account-creation password policy. It intentionally
// avoids composition rules (uppercase/symbol requirements), which encourage
// predictable substitutions and reject strong passphrases. Existing password
// verification does not call this function so future policy changes cannot lock
// users out before they can authenticate and rehash/reset.
func ValidatePolicy(plaintext string) error {
	if !utf8.ValidString(plaintext) {
		return errors.New("password must be valid UTF-8")
	}
	if strings.ContainsRune(plaintext, '\x00') {
		return errors.New("password must not contain NUL")
	}
	if len([]byte(plaintext)) > maxPasswordBytes {
		return fmt.Errorf("password exceeds %d bytes", maxPasswordBytes)
	}
	length := utf8.RuneCountInString(plaintext)
	if length < minimumPasswordRunes || length > maximumPasswordRunes {
		return fmt.Errorf("password must contain %d-%d characters", minimumPasswordRunes, maximumPasswordRunes)
	}
	return nil
}
