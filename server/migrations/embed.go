package migrations

import "embed"

// Files embeds every ordered SQL migration into the migrate binary so deployment
// does not depend on a sidecar migrations directory.
//
//go:embed *.sql
var Files embed.FS
