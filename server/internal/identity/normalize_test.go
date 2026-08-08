package identity

import "testing"

func TestNormalizeHandle(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "trim and lowercase", input: "  Liang_01  ", want: "liang_01"},
		{name: "unicode compatibility fold", input: "Ｌiang_01", want: "liang_01"},
		{name: "minimum", input: "abc", want: "abc"},
		{name: "reserved admin", input: "ADMIN", wantErr: true},
		{name: "reserved dd", input: "dd", wantErr: true},
		{name: "must start with letter", input: "1liang", wantErr: true},
		{name: "hyphen forbidden", input: "liang-01", wantErr: true},
		{name: "unicode handle rejected", input: "良哥", wantErr: true},
		{name: "too short", input: "ab", wantErr: true},
		{name: "too long", input: "abcdefghijklmnopqrstuvwxyz1234567", wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := NormalizeHandle(test.input)
			if test.wantErr {
				if err == nil {
					t.Fatalf("NormalizeHandle(%q) = %q, want error", test.input, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("NormalizeHandle(%q) error = %v", test.input, err)
			}
			if got != test.want {
				t.Fatalf("NormalizeHandle(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestNormalizeEmail(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "trim lowercase", input: "  USER+Tag@Example.COM  ", want: "user+tag@example.com"},
		{name: "idn domain", input: "User@bücher.example", want: "user@xn--bcher-kva.example"},
		{name: "compatibility characters", input: "ＵSER@example.com", want: "user@example.com"},
		{name: "missing at", input: "user.example.com", wantErr: true},
		{name: "multiple at", input: "a@b@example.com", wantErr: true},
		{name: "quoted local deliberately unsupported", input: "\"User Name\"@example.com", wantErr: true},
		{name: "international local deliberately unsupported", input: "良@example.com", wantErr: true},
		{name: "leading local dot", input: ".user@example.com", wantErr: true},
		{name: "consecutive local dot", input: "user..name@example.com", wantErr: true},
		{name: "bad domain label", input: "user@-example.com", wantErr: true},
		{name: "whitespace", input: "user name@example.com", wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := NormalizeEmail(test.input)
			if test.wantErr {
				if err == nil {
					t.Fatalf("NormalizeEmail(%q) = %q, want error", test.input, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("NormalizeEmail(%q) error = %v", test.input, err)
			}
			if got != test.want {
				t.Fatalf("NormalizeEmail(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}
