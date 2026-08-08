package maildelivery

import "testing"

func TestNewSMTPMailerValidatesConfiguration(t *testing.T) {
	good := SMTPConfig{
		Host:       "127.0.0.1",
		Port:       11025,
		From:       "noreply@dd.local",
		RequireTLS: false,
	}
	if _, err := NewSMTPMailer(good); err != nil {
		t.Fatalf("NewSMTPMailer(good) error = %v", err)
	}

	bad := []SMTPConfig{
		{Port: 11025, From: "noreply@dd.local"},
		{Host: "127.0.0.1", Port: 0, From: "noreply@dd.local"},
		{Host: "127.0.0.1", Port: 11025, From: "bad\r\nBcc: attacker@example.com"},
		{Host: "127.0.0.1", Port: 11025, From: "noreply@dd.local", Username: "user"},
	}
	for _, config := range bad {
		if _, err := NewSMTPMailer(config); err == nil {
			t.Fatalf("NewSMTPMailer(%#v) unexpectedly succeeded", config)
		}
	}
}

func TestBuildVerificationMessageDoesNotPermitHeaderInjection(t *testing.T) {
	mailer, err := NewSMTPMailer(SMTPConfig{
		Host: "127.0.0.1",
		Port: 11025,
		From: "noreply@dd.local",
	})
	if err != nil {
		t.Fatalf("NewSMTPMailer() error = %v", err)
	}

	if _, err := mailer.buildVerificationMessage("victim@example.com\r\nBcc: attacker@example.com", "REGISTER", "123456"); err == nil {
		t.Fatal("header injection recipient unexpectedly accepted")
	}
	message, err := mailer.buildVerificationMessage("victim@example.com", "REGISTER", "123456")
	if err != nil {
		t.Fatalf("buildVerificationMessage() error = %v", err)
	}
	for _, want := range []string{"To: victim@example.com", "123456", "Content-Type: text/plain; charset=UTF-8"} {
		if !contains(message, want) {
			t.Fatalf("message missing %q:\n%s", want, message)
		}
	}
}

func contains(haystack, needle string) bool {
	return len(needle) == 0 || (len(haystack) >= len(needle) && stringContains(haystack, needle))
}

func stringContains(haystack, needle string) bool {
	for index := 0; index+len(needle) <= len(haystack); index++ {
		if haystack[index:index+len(needle)] == needle {
			return true
		}
	}
	return false
}
