package password

import (
	"strings"
	"testing"
)

func testHasher(t *testing.T) *Hasher {
	t.Helper()
	hasher, err := NewHasher(Params{
		MemoryKiB:   8 * 1024,
		Iterations:  1,
		Parallelism: 1,
		SaltLength:  16,
		KeyLength:   32,
	})
	if err != nil {
		t.Fatalf("NewHasher() error = %v", err)
	}
	return hasher
}

func TestHashAndVerify(t *testing.T) {
	hasher := testHasher(t)
	encoded, err := hasher.Hash("correct horse battery staple")
	if err != nil {
		t.Fatalf("Hash() error = %v", err)
	}
	if strings.Contains(encoded, "correct horse") {
		t.Fatal("encoded hash leaked plaintext password")
	}
	if !strings.HasPrefix(encoded, "$argon2id$v=19$") {
		t.Fatalf("encoded = %q", encoded)
	}

	result, err := hasher.Verify(encoded, "correct horse battery staple")
	if err != nil {
		t.Fatalf("Verify(correct) error = %v", err)
	}
	if !result.Match || result.NeedsRehash {
		t.Fatalf("Verify(correct) = %#v", result)
	}

	result, err = hasher.Verify(encoded, "wrong password")
	if err != nil {
		t.Fatalf("Verify(wrong) error = %v", err)
	}
	if result.Match {
		t.Fatal("wrong password matched")
	}
}

func TestHashUsesIndependentSalt(t *testing.T) {
	hasher := testHasher(t)
	first, err := hasher.Hash("same password")
	if err != nil {
		t.Fatalf("first Hash() error = %v", err)
	}
	second, err := hasher.Hash("same password")
	if err != nil {
		t.Fatalf("second Hash() error = %v", err)
	}
	if first == second {
		t.Fatal("two hashes of the same password must use independent salts")
	}
}

func TestVerifyMarksOldParametersForRehash(t *testing.T) {
	oldHasher := testHasher(t)
	encoded, err := oldHasher.Hash("upgrade me")
	if err != nil {
		t.Fatalf("Hash() error = %v", err)
	}
	newHasher, err := NewHasher(Params{
		MemoryKiB:   12 * 1024,
		Iterations:  2,
		Parallelism: 1,
		SaltLength:  16,
		KeyLength:   32,
	})
	if err != nil {
		t.Fatalf("NewHasher(new) error = %v", err)
	}

	result, err := newHasher.Verify(encoded, "upgrade me")
	if err != nil {
		t.Fatalf("Verify() error = %v", err)
	}
	if !result.Match || !result.NeedsRehash {
		t.Fatalf("Verify() = %#v, want match + rehash", result)
	}
}

func TestVerifyRejectsMalformedHashWithoutPanicking(t *testing.T) {
	hasher := testHasher(t)
	malformed := []string{
		"",
		"not-a-phc-string",
		"$argon2i$v=19$m=8192,t=1,p=1$abc$def",
		"$argon2id$v=18$m=8192,t=1,p=1$abc$def",
		"$argon2id$v=19$m=nope,t=1,p=1$abc$def",
		"$argon2id$v=19$m=8192,t=0,p=1$abc$def",
	}
	for _, encoded := range malformed {
		if _, err := hasher.Verify(encoded, "password"); err == nil {
			t.Fatalf("Verify(%q) unexpectedly succeeded", encoded)
		}
	}
}

func TestValidatePolicyUsesLengthInsteadOfCompositionRules(t *testing.T) {
	valid := []string{
		"correct horse battery staple",
		"这是一个足够长的密码短语",
		"0123456789",
	}
	for _, plaintext := range valid {
		if err := ValidatePolicy(plaintext); err != nil {
			t.Fatalf("ValidatePolicy(%q) error = %v", plaintext, err)
		}
	}

	invalid := []string{"short", "password\x00hidden", strings.Repeat("x", 257)}
	for _, plaintext := range invalid {
		if err := ValidatePolicy(plaintext); err == nil {
			t.Fatalf("ValidatePolicy(%q) unexpectedly succeeded", plaintext)
		}
	}
}

func TestNewHasherRejectsUnsafeOrNonsensicalParameters(t *testing.T) {
	bad := []Params{
		{MemoryKiB: 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32},
		{MemoryKiB: 8192, Iterations: 0, Parallelism: 1, SaltLength: 16, KeyLength: 32},
		{MemoryKiB: 8192, Iterations: 1, Parallelism: 0, SaltLength: 16, KeyLength: 32},
		{MemoryKiB: 8192, Iterations: 1, Parallelism: 1, SaltLength: 8, KeyLength: 32},
		{MemoryKiB: 8192, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 8},
	}
	for _, params := range bad {
		if _, err := NewHasher(params); err == nil {
			t.Fatalf("NewHasher(%#v) unexpectedly succeeded", params)
		}
	}
}
