package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/emailcode"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/auth/session"
	"example.com/selfhosted-im/server/internal/contacts"
	"example.com/selfhosted-im/server/internal/httpapi"
	"example.com/selfhosted-im/server/internal/messaging"
	"example.com/selfhosted-im/server/internal/platform/appconfig"
	"example.com/selfhosted-im/server/internal/platform/database"
	"example.com/selfhosted-im/server/internal/platform/maildelivery"
	"example.com/selfhosted-im/server/internal/realtimebus"
)

var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	config, err := appconfig.Load()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(2)
	}

	readinessChecks := make(map[string]httpapi.ReadinessCheck)
	var authService httpapi.AuthService
	var contactsService httpapi.ContactsService
	var messagingService httpapi.MessagingService
	var realtimeEventBus httpapi.RealtimeEventBus
	if config.DatabaseURL != "" {
		startupContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		pool, err := database.Open(startupContext, config.DatabaseURL)
		cancel()
		if err != nil {
			logger.Error("database startup failed", "error", err)
			os.Exit(1)
		}
		defer pool.Close()
		readinessChecks["postgres"] = func(ctx context.Context) error {
			return database.Ping(ctx, pool)
		}

		hasher := password.NewDefaultHasher()
		sessionManager, err := session.NewManager(session.Config{Secret: config.AuthTokenSecret})
		if err != nil {
			logger.Error("auth session initialization failed", "error", err)
			os.Exit(2)
		}
		var codeCodec *emailcode.Codec
		var mailer account.Mailer
		if config.RegistrationMode == appconfig.RegistrationOpen {
			codeCodec, err = emailcode.NewCodec([]byte(config.EmailCodePepper))
			if err != nil {
				logger.Error("email code initialization failed", "error", err)
				os.Exit(2)
			}
			mailer, err = maildelivery.NewSMTPMailer(maildelivery.SMTPConfig{
				Host: config.SMTPHost, Port: config.SMTPPort, From: config.SMTPFrom,
				Username: config.SMTPUsername, Password: config.SMTPPassword, RequireTLS: config.SMTPRequireTLS,
			})
			if err != nil {
				logger.Error("SMTP initialization failed", "error", err)
				os.Exit(2)
			}
		}
		authService, err = account.NewService(account.Config{
			Pool: pool, Codec: codeCodec, Hasher: hasher, Sessions: sessionManager,
			Mailer: mailer, RegistrationMode: string(config.RegistrationMode),
		})
		if err != nil {
			logger.Error("authentication service initialization failed", "error", err)
			os.Exit(2)
		}
		contactsService, err = contacts.NewService(contacts.Config{Pool: pool})
		if err != nil {
			logger.Error("contacts service initialization failed", "error", err)
			os.Exit(2)
		}
		messagingService, err = messaging.NewService(messaging.Config{Pool: pool})
		if err != nil {
			logger.Error("messaging service initialization failed", "error", err)
			os.Exit(2)
		}
	}

	if config.RedisURL != "" {
		hostname, hostErr := os.Hostname()
		if hostErr != nil || hostname == "" {
			hostname = "dd-api"
		}
		nodeID := fmt.Sprintf("%s-%d", hostname, os.Getpid())
		startupContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		redisBus, redisErr := realtimebus.NewRedisBus(startupContext, config.RedisURL, nodeID)
		cancel()
		if redisErr != nil {
			logger.Error("realtime redis startup failed", "error", redisErr)
			os.Exit(1)
		}
		defer redisBus.Close()
		realtimeEventBus = redisBus
		readinessChecks["redis"] = redisBus.Ping
	}

	server := &http.Server{
		Addr: ":" + strconv.Itoa(config.Port),
		Handler: httpapi.NewHandler(httpapi.Config{
			Version:            version,
			PublicBaseURL:      config.PublicBaseURL,
			InstanceName:       config.InstanceName,
			RegistrationMode:   string(config.RegistrationMode),
			AllowedOrigins:     config.AllowedOrigins,
			AllowedHTTPOrigins: config.AllowedHTTPOrigins,
			LiveKitURL:         config.LiveKitURL,
			LiveKitPublicPort:  config.LiveKitPublicPort,
			LiveKitAPIKey:      config.LiveKitAPIKey,
			LiveKitAPISecret:   config.LiveKitAPISecret,
			ReadinessChecks:    readinessChecks,
			AuthService:        authService,
			ContactsService:    contactsService,
			MessagingService:   messagingService,
			RealtimeEventBus:   realtimeEventBus,
			Logger:             logger,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}

	shutdownContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errorChannel := make(chan error, 1)
	go func() {
		logger.Info("realtime poc listening", "address", server.Addr, "version", version)
		errorChannel <- server.ListenAndServe()
	}()

	select {
	case err := <-errorChannel:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server stopped unexpectedly", "error", err)
			os.Exit(1)
		}
	case <-shutdownContext.Done():
		logger.Info("shutdown requested")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}

	logger.Info("server stopped")
}
