package migration

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
)

type Migration struct {
	Version  int64
	Name     string
	UpSQL    string
	DownSQL  string
	Checksum string
}

type migrationParts struct {
	version int64
	name    string
	up      string
	down    string
}

func Load(files fs.FS) ([]Migration, error) {
	entries, err := fs.ReadDir(files, ".")
	if err != nil {
		return nil, fmt.Errorf("read migrations: %w", err)
	}

	byVersion := make(map[int64]*migrationParts)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		version, name, direction, ok := parseMigrationFilename(entry.Name())
		if !ok {
			return nil, fmt.Errorf("invalid migration filename %q", entry.Name())
		}
		contents, err := fs.ReadFile(files, entry.Name())
		if err != nil {
			return nil, fmt.Errorf("read migration %q: %w", entry.Name(), err)
		}
		parts, exists := byVersion[version]
		if !exists {
			parts = &migrationParts{version: version, name: name}
			byVersion[version] = parts
		} else if parts.name != name {
			return nil, fmt.Errorf("migration version %06d is used by both %q and %q", version, parts.name, name)
		}
		sql := strings.TrimSpace(string(contents))
		if sql == "" {
			return nil, fmt.Errorf("migration %q is empty", entry.Name())
		}
		switch direction {
		case "up":
			if parts.up != "" {
				return nil, fmt.Errorf("migration %06d has duplicate up file", version)
			}
			parts.up = sql
		case "down":
			if parts.down != "" {
				return nil, fmt.Errorf("migration %06d has duplicate down file", version)
			}
			parts.down = sql
		}
	}

	versions := make([]int64, 0, len(byVersion))
	for version := range byVersion {
		versions = append(versions, version)
	}
	sort.Slice(versions, func(i, j int) bool { return versions[i] < versions[j] })

	result := make([]Migration, 0, len(versions))
	for _, version := range versions {
		parts := byVersion[version]
		if parts.up == "" || parts.down == "" {
			return nil, fmt.Errorf("migration %06d_%s requires both .up.sql and .down.sql", version, parts.name)
		}
		hash := sha256.Sum256([]byte(parts.up))
		result = append(result, Migration{
			Version:  version,
			Name:     parts.name,
			UpSQL:    parts.up,
			DownSQL:  parts.down,
			Checksum: hex.EncodeToString(hash[:]),
		})
	}
	return result, nil
}

func parseMigrationFilename(filename string) (int64, string, string, bool) {
	base := strings.TrimSuffix(filename, ".sql")
	directionSeparator := strings.LastIndexByte(base, '.')
	if directionSeparator <= 0 {
		return 0, "", "", false
	}
	direction := base[directionSeparator+1:]
	if direction != "up" && direction != "down" {
		return 0, "", "", false
	}
	prefix := base[:directionSeparator]
	nameSeparator := strings.IndexByte(prefix, '_')
	if nameSeparator != 6 || len(prefix) <= 7 {
		return 0, "", "", false
	}
	version, err := strconv.ParseInt(prefix[:nameSeparator], 10, 64)
	if err != nil || version <= 0 {
		return 0, "", "", false
	}
	name := prefix[nameSeparator+1:]
	for _, character := range name {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '_' || character == '-' {
			continue
		}
		return 0, "", "", false
	}
	return version, name, direction, true
}
