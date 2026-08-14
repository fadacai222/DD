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

	"example.com/selfhosted-im/server/internal/admin"
	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/emailcode"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/auth/session"
	"example.com/selfhosted-im/server/internal/calls"
	"example.com/selfhosted-im/server/internal/contacts"
	"example.com/selfhosted-im/server/internal/datarights"
	"example.com/selfhosted-im/server/internal/groups"
	"example.com/selfhosted-im/server/internal/httpapi"
	"example.com/selfhosted-im/server/internal/media"
	"example.com/selfhosted-im/server/internal/messaging"
	"example.com/selfhosted-im/server/internal/moments"
	"example.com/selfhosted-im/server/internal/observability"
	"example.com/selfhosted-im/server/internal/platform/appconfig"
	"example.com/selfhosted-im/server/internal/platform/database"
	"example.com/selfhosted-im/server/internal/platform/maildelivery"
	"example.com/selfhosted-im/server/internal/push"
	"example.com/selfhosted-im/server/internal/qrcode"
	"example.com/selfhosted-im/server/internal/realtimebus"
	"example.com/selfhosted-im/server/internal/stickers"
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
	metrics := observability.New("api", version)
	shutdownContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	readinessChecks := make(map[string]httpapi.ReadinessCheck)
	var authService httpapi.AuthService
	var adminService *admin.Service
	var contactsService httpapi.ContactsService
	var groupsService httpapi.GroupsService
	var callsService httpapi.CallsService
	var messagingService httpapi.MessagingService
	var mediaService httpapi.MediaService
	var stickersService httpapi.StickersService
	var momentsService httpapi.MomentsService
	var qrService httpapi.QRService
	var pushService httpapi.PushService
	var dataRightsService httpapi.DataRightsService
	var realtimeEventBus httpapi.RealtimeEventBus
	var telegramIntegration *stickers.TelegramProviderManager
	if config.DatabaseURL != "" {
		startupContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		pool, err := database.Open(startupContext, config.DatabaseURL, metrics)
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
				Observer: metrics,
			})
			if err != nil {
				logger.Error("SMTP initialization failed", "error", err)
				os.Exit(2)
			}
		}
		accountService, accountErr := account.NewService(account.Config{
			Pool: pool, Codec: codeCodec, Hasher: hasher, Sessions: sessionManager,
			Mailer: mailer, RegistrationMode: string(config.RegistrationMode),
		})
		if accountErr != nil {
			err = accountErr
			logger.Error("authentication service initialization failed", "error", err)
			os.Exit(2)
		}
		adminService, err = admin.NewService(admin.Config{Pool: pool, Hasher: hasher, Secret: config.AdminSecuritySecret})
		if err != nil {
			logger.Error("admin service initialization failed", "error", err)
			os.Exit(2)
		}
		contactsService, err = contacts.NewService(contacts.Config{Pool: pool})
		if err != nil {
			logger.Error("contacts service initialization failed", "error", err)
			os.Exit(2)
		}
		authService = accountService
		groupService, groupErr := groups.NewService(groups.Config{Pool: pool})
		if groupErr != nil {
			err = groupErr
			logger.Error("groups service initialization failed", "error", err)
			os.Exit(2)
		}
		groupsService = groupService
		callsService, err = calls.NewService(calls.Config{Pool: pool})
		if err != nil {
			logger.Error("calls service initialization failed", "error", err)
			os.Exit(2)
		}
		messagingService, err = messaging.NewService(messaging.Config{Pool: pool})
		if err != nil {
			logger.Error("messaging service initialization failed", "error", err)
			os.Exit(2)
		}
		var managedMedia *media.Service
		var dataRightsStore datarights.ArtifactStore
		if config.MediaS3Endpoint != "" {
			mediaStore, storeErr := media.NewS3Store(media.S3Config{
				Endpoint:  config.MediaS3Endpoint,
				Bucket:    config.MediaS3Bucket,
				Region:    config.MediaS3Region,
				AccessKey: config.MediaS3AccessKey,
				SecretKey: config.MediaS3SecretKey,
				Observer:  metrics,
			})
			if storeErr != nil {
				logger.Error("media object storage initialization failed", "error", storeErr)
				os.Exit(2)
			}
			dataRightsStore = mediaStore
			managedMedia, err = media.NewService(media.Config{Pool: pool, Store: mediaStore})
			if err != nil {
				logger.Error("media service initialization failed", "error", err)
				os.Exit(2)
			}
			mediaService = managedMedia
		}
		telegramToken := config.TelegramBotToken
		telegramSource := stickers.TelegramIntegrationSourceNone
		var telegramUpdatedAt *time.Time
		if telegramToken != "" {
			telegramSource = stickers.TelegramIntegrationSourceEnvironment
		}
		secretContext, cancelSecretLoad := context.WithTimeout(context.Background(), 5*time.Second)
		storedTelegram, secretErr := adminService.LoadIntegrationSecret(secretContext, admin.IntegrationTelegramBotToken)
		cancelSecretLoad()
		if secretErr == nil {
			telegramToken = storedTelegram.Value
			telegramSource = stickers.TelegramIntegrationSourceAdmin
			telegramUpdatedAt = &storedTelegram.UpdatedAt
		} else if !errors.Is(secretErr, admin.ErrNotFound) {
			logger.Error("telegram sticker admin configuration load failed", "error", secretErr)
			os.Exit(2)
		}
		telegramIntegration, err = stickers.NewTelegramProviderManager(
			stickers.TelegramBotProviderConfig{Token: telegramToken}, telegramSource, telegramUpdatedAt,
		)
		if err != nil {
			logger.Error("telegram sticker relay initialization failed", "error", err)
			os.Exit(2)
		}
		stickersService, err = stickers.NewService(stickers.Config{Pool: pool, Provider: telegramIntegration, Media: managedMedia})
		if err != nil {
			logger.Error("sticker service initialization failed", "error", err)
			os.Exit(2)
		}
		momentsService, err = moments.NewService(moments.Config{Pool: pool})
		if err != nil {
			logger.Error("moments service initialization failed", "error", err)
			os.Exit(2)
		}
		qrOrigin := config.PublicBaseURL
		if qrOrigin == "" {
			qrOrigin = fmt.Sprintf("http://127.0.0.1:%d", config.Port)
		}
		qrService, err = qrcode.NewService(qrcode.Config{
			Pool: pool, PublicBaseURL: qrOrigin, Auth: accountService, Groups: groupService,
		})
		if err != nil {
			logger.Error("qr service initialization failed", "error", err)
			os.Exit(2)
		}
		pushService, err = push.NewService(push.Config{Pool: pool, Observer: metrics})
		if err != nil {
			logger.Error("push service initialization failed", "error", err)
			os.Exit(2)
		}
		dataRightsService, err = datarights.NewService(datarights.Config{Pool: pool, Hasher: hasher, Store: dataRightsStore})
		if err != nil {
			logger.Error("data rights service initialization failed", "error", err)
			os.Exit(2)
		}
		go metrics.RunDatabaseSampler(shutdownContext, pool, 15*time.Second)
	}

	if config.RedisURL != "" {
		hostname, hostErr := os.Hostname()
		if hostErr != nil || hostname == "" {
			hostname = "dd-api"
		}
		nodeID := fmt.Sprintf("%s-%d", hostname, os.Getpid())
		startupContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		redisBus, redisErr := realtimebus.NewRedisBus(startupContext, config.RedisURL, nodeID, metrics)
		cancel()
		if redisErr != nil {
			logger.Error("realtime redis startup failed", "error", redisErr)
			os.Exit(1)
		}
		defer redisBus.Close()
		realtimeEventBus = redisBus
		readinessChecks["redis"] = redisBus.Ping
	}
	go metrics.RunDependencySampler(shutdownContext, mapReadinessChecks(readinessChecks), 15*time.Second)

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
			AdminService:               adminService,
			TelegramIntegrationService: telegramIntegration,
			AdminWebRoot:               config.AdminWebRoot,
			ContactsService:    contactsService,
			GroupsService:      groupsService,
			CallsService:       callsService,
			MessagingService:   messagingService,
			MediaService:       mediaService,
			StickersService:    stickersService,
			MomentsService:     momentsService,
			QRService:          qrService,
			PushService:        pushService,
			DataRightsService:  dataRightsService,
			PushAvatarSecret:   config.AuthTokenSecret,
			RealtimeEventBus:   realtimeEventBus,
			Metrics:            metrics,
			Logger:             logger,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}

	observabilityServer, err := observability.StartServer(
		os.Getenv("DD_API_OBSERVABILITY_ADDR"),
		observability.NewOperationalHandler(metrics.Handler(), mapReadinessChecks(readinessChecks)),
	)
	if err != nil {
		logger.Error("observability listener startup failed", "error", err)
		os.Exit(1)
	}
	if observabilityServer != nil {
		logger.Info("observability listener started", "address", observabilityServer.Address())
		defer func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = observabilityServer.Shutdown(ctx)
		}()
	}

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

func mapReadinessChecks(checks map[string]httpapi.ReadinessCheck) map[string]observability.ReadinessCheck {
	mapped := make(map[string]observability.ReadinessCheck, len(checks))
	for name, check := range checks {
		mapped[name] = observability.ReadinessCheck(check)
	}
	return mapped
}
