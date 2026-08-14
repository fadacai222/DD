package admin

import (
	"strings"
	"testing"

	"example.com/selfhosted-im/server/internal/auth/password"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestAdminServiceRejectsMissingOrWeakSecuritySecret(t *testing.T) {
	for _, secret := range []string{"", strings.Repeat("x", 31)} {
		if _, err := NewService(Config{
			Pool: &pgxpool.Pool{}, Hasher: password.NewDefaultHasher(), Secret: secret,
		}); err == nil || !strings.Contains(err.Error(), "at least 32 bytes") {
			t.Fatalf("NewService(secret length=%d) error=%v, want minimum-strength rejection", len(secret), err)
		}
	}
}

func TestAdminIntegrationSecretUsesSeparateCryptographicDomain(t *testing.T) {
	master := strings.Repeat("s", 40)
	mfaBox, err := newSecretBox(master)
	if err != nil {
		t.Fatal(err)
	}
	integrationBox, err := newPurposeSecretBox(master, "dd-admin-integration-secret-v1")
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, err := integrationBox.encrypt([]byte("123456:bot-token"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := mfaBox.decrypt(ciphertext); err == nil {
		t.Fatal("MFA cryptographic domain unexpectedly decrypted integration secret")
	}
	plaintext, err := integrationBox.decrypt(ciphertext)
	if err != nil || string(plaintext) != "123456:bot-token" {
		t.Fatalf("integration decrypt = %q, %v", plaintext, err)
	}
}

func TestAdminSecretCryptographyIsIndependentFromOrdinaryAuthSecret(t *testing.T) {
	adminSecret := strings.Repeat("m", 40)
	ordinaryAuthSecretBefore := strings.Repeat("a", 40)
	ordinaryAuthSecretAfter := strings.Repeat("b", 40)
	if ordinaryAuthSecretBefore == ordinaryAuthSecretAfter || adminSecret == ordinaryAuthSecretAfter {
		t.Fatal("test secrets must be distinct")
	}

	before, err := newSecretBox(adminSecret)
	if err != nil {
		t.Fatalf("new admin secret box before auth rotation: %v", err)
	}
	totpSecret := []byte("JBSWY3DPEHPK3PXP")
	ciphertext, err := before.encrypt(totpSecret)
	if err != nil {
		t.Fatalf("encrypt TOTP secret: %v", err)
	}

	// Rotating the ordinary user AUTH_TOKEN_SECRET must not change the
	// cryptographic root used to decrypt existing administrator MFA data.
	_ = ordinaryAuthSecretBefore
	_ = ordinaryAuthSecretAfter
	after, err := newSecretBox(adminSecret)
	if err != nil {
		t.Fatalf("new admin secret box after auth rotation: %v", err)
	}
	plaintext, err := after.decrypt(ciphertext)
	if err != nil {
		t.Fatalf("decrypt TOTP secret after ordinary auth secret rotation: %v", err)
	}
	if string(plaintext) != string(totpSecret) {
		t.Fatalf("decrypted TOTP secret = %q, want %q", plaintext, totpSecret)
	}

	// Prove that the ordinary auth secret is not interchangeable with the Admin
	// security secret: an Admin box rooted in AUTH_TOKEN_SECRET cannot decrypt
	// ciphertext created with ADMIN_SECURITY_SECRET.
	wrongRoot, err := newSecretBox(ordinaryAuthSecretAfter)
	if err != nil {
		t.Fatalf("new wrong-root box: %v", err)
	}
	if _, err := wrongRoot.decrypt(ciphertext); err == nil {
		t.Fatal("ordinary AUTH_TOKEN_SECRET unexpectedly decrypted Admin TOTP data")
	}

	rawSession := "dda_test-session-token"
	if before.csrfToken(rawSession) != after.csrfToken(rawSession) {
		t.Fatal("Admin CSRF derivation changed even though ADMIN_SECURITY_SECRET stayed fixed")
	}
}
