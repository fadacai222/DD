package emailcode

import (
	"bytes"
	"testing"
)

func TestGenerateProducesSixDigitCodes(t *testing.T) {
	codec, err := NewCodec(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("NewCodec() error = %v", err)
	}

	seen := make(map[string]struct{})
	for range 100 {
		code, err := codec.Generate()
		if err != nil {
			t.Fatalf("Generate() error = %v", err)
		}
		if len(code) != 6 {
			t.Fatalf("code = %q, want 6 digits", code)
		}
		for _, character := range code {
			if character < '0' || character > '9' {
				t.Fatalf("code = %q, contains non-digit", code)
			}
		}
		seen[code] = struct{}{}
	}
	if len(seen) < 95 {
		t.Fatalf("only %d unique codes in 100 generations", len(seen))
	}
}

func TestHashAndVerifyBindCodeToEmailAndPurpose(t *testing.T) {
	codec, err := NewCodec(bytes.Repeat([]byte{0x24}, 32))
	if err != nil {
		t.Fatalf("NewCodec() error = %v", err)
	}

	hash := codec.Hash("user@example.com", PurposeRegister, "123456")
	if len(hash) != 32 {
		t.Fatalf("hash length = %d, want 32", len(hash))
	}
	if !codec.Verify(hash, "user@example.com", PurposeRegister, "123456") {
		t.Fatal("correct code did not verify")
	}
	if codec.Verify(hash, "other@example.com", PurposeRegister, "123456") {
		t.Fatal("hash verified for another email")
	}
	if codec.Verify(hash, "user@example.com", PurposePasswordReset, "123456") {
		t.Fatal("hash verified for another purpose")
	}
	if codec.Verify(hash, "user@example.com", PurposeRegister, "654321") {
		t.Fatal("wrong code verified")
	}
}

func TestHashMetadataIsScopedAndDeterministic(t *testing.T) {
	codec, err := NewCodec(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatalf("NewCodec() error = %v", err)
	}
	first := codec.HashMetadata("ip", "192.0.2.1")
	second := codec.HashMetadata("ip", "192.0.2.1")
	otherScope := codec.HashMetadata("device", "192.0.2.1")
	if !bytes.Equal(first, second) {
		t.Fatal("metadata hash must be deterministic")
	}
	if bytes.Equal(first, otherScope) {
		t.Fatal("metadata hash must be domain-separated by scope")
	}
}

func TestNewCodecRejectsWeakPepper(t *testing.T) {
	if _, err := NewCodec([]byte("too-short")); err == nil {
		t.Fatal("NewCodec() unexpectedly accepted weak pepper")
	}
}
