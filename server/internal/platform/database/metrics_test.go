package database

import "testing"

func TestSQLOperationIsBounded(t *testing.T) {
	tests := map[string]string{
		" SELECT * FROM users WHERE id=$1":           "SELECT",
		"insert into users(id) values($1)":           "INSERT",
		"WITH rows AS (SELECT 1) SELECT * FROM rows": "OTHER",
		"": "OTHER",
	}
	for sql, want := range tests {
		if got := sqlOperation(sql); got != want {
			t.Fatalf("sqlOperation(%q)=%q want=%q", sql, got, want)
		}
	}
}
