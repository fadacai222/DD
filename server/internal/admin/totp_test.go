package admin

import (
	"testing"
	"time"
)

func TestTOTPVerificationWindowAndReplayCounter(t *testing.T) {
	secret := "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
	now := time.Unix(1_700_000_000, 0).UTC()
	counter := now.Unix() / totpPeriodSeconds
	code, err := totpAtCounter(secret, counter)
	if err != nil {
		t.Fatal(err)
	}
	gotCounter, ok := verifyTOTP(secret, code, now)
	if !ok || gotCounter != counter {
		t.Fatalf("verifyTOTP counter=%d ok=%v want counter=%d", gotCounter, ok, counter)
	}
	if _, ok := verifyTOTP(secret, "00000x", now); ok {
		t.Fatal("non-numeric TOTP must be rejected")
	}
	if _, ok := verifyTOTP(secret, code, now.Add(2*time.Minute)); ok {
		t.Fatal("stale TOTP outside the allowed drift window must be rejected")
	}
}

func TestRecoveryCodeHashNormalization(t *testing.T) {
	left := hashRecoveryCode("ABCD-EFGH-IJKL")
	right := hashRecoveryCode("abcd efgh ijkl")
	if string(left) == string(right) {
		t.Fatal("spaces are not an accepted recovery-code separator")
	}
	if string(left) != string(hashRecoveryCode("abcdefghiJKL")) {
		t.Fatal("case and hyphen normalization should be stable")
	}
}
