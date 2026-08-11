package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/admin"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/platform/appconfig"
	"example.com/selfhosted-im/server/internal/platform/database"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "create" {
		fmt.Fprintln(os.Stderr, "usage: adminctl create -email admin@example.com [-role SUPER_ADMIN]")
		os.Exit(2)
	}
	command := flag.NewFlagSet("create", flag.ExitOnError)
	email := command.String("email", "", "administrator email")
	roleValue := command.String("role", string(admin.RoleSuperAdmin), "SUPER_ADMIN, MODERATOR, or SUPPORT_READ_ONLY")
	_ = command.Parse(os.Args[2:])

	databaseURL, err := appconfig.ReadSecret("DATABASE_URL")
	if err != nil {
		fatal(err)
	}
	masterSecret, err := appconfig.ReadSecret("AUTH_TOKEN_SECRET")
	if err != nil {
		fatal(err)
	}
	passwordValue, err := appconfig.ReadSecret("ADMIN_BOOTSTRAP_PASSWORD")
	if err != nil {
		fatal(err)
	}
	if strings.TrimSpace(databaseURL) == "" || strings.TrimSpace(masterSecret) == "" || strings.TrimSpace(passwordValue) == "" {
		fatal(fmt.Errorf("DATABASE_URL, AUTH_TOKEN_SECRET, and ADMIN_BOOTSTRAP_PASSWORD (or *_FILE) are required"))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := database.Open(ctx, databaseURL)
	if err != nil {
		fatal(err)
	}
	defer pool.Close()
	service, err := admin.NewService(admin.Config{Pool: pool, Hasher: password.NewDefaultHasher(), Secret: masterSecret})
	if err != nil {
		fatal(err)
	}
	identity, err := service.BootstrapAdmin(ctx, *email, passwordValue, admin.Role(strings.ToUpper(strings.TrimSpace(*roleValue))))
	if err != nil {
		fatal(err)
	}
	fmt.Printf("created administrator %s (%s) role=%s\n", identity.Email, identity.ID, identity.Role)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "adminctl:", err)
	os.Exit(1)
}
