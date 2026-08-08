package password

import "testing"

func BenchmarkDefaultHash(b *testing.B) {
	hasher := NewDefaultHasher()
	b.ReportAllocs()
	for b.Loop() {
		if _, err := hasher.Hash("benchmark-only-password-value"); err != nil {
			b.Fatal(err)
		}
	}
}
