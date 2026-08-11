package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/datarights"
	"example.com/selfhosted-im/server/internal/media"
	"example.com/selfhosted-im/server/internal/messaging"
	"example.com/selfhosted-im/server/internal/platform/appconfig"
	"example.com/selfhosted-im/server/internal/platform/database"
	"example.com/selfhosted-im/server/internal/push"
	"example.com/selfhosted-im/server/internal/stickers"
)

var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	databaseURL, err := appconfig.ReadSecret("DATABASE_URL")
	if err != nil {
		logger.Error("worker database configuration failed", "error", err)
		os.Exit(2)
	}
	if databaseURL == "" {
		logger.Error("worker requires DATABASE_URL or DATABASE_URL_FILE")
		os.Exit(2)
	}

	startupContext, cancel := context.WithTimeout(ctx, 10*time.Second)
	pool, err := database.Open(startupContext, databaseURL)
	cancel()
	if err != nil {
		logger.Error("worker database startup failed", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	messagingService, err := messaging.NewService(messaging.Config{Pool: pool})
	if err != nil {
		logger.Error("worker messaging initialization failed", "error", err)
		os.Exit(2)
	}
	stickerService, err := stickers.NewService(stickers.Config{Pool: pool})
	if err != nil {
		logger.Error("worker sticker initialization failed", "error", err)
		os.Exit(2)
	}
	authTokenSecret, err := appconfig.ReadSecret("AUTH_TOKEN_SECRET")
	if err != nil {
		logger.Error("worker auth token secret configuration failed", "error", err)
		os.Exit(2)
	}
	pushService, err := push.NewService(push.Config{
		Pool:              pool,
		PublicBaseURL:     strings.TrimRight(strings.TrimSpace(os.Getenv("IM_PUBLIC_BASE_URL")), "/"),
		AvatarTokenSecret: authTokenSecret,
	})
	if err != nil {
		logger.Error("worker push initialization failed", "error", err)
		os.Exit(2)
	}
	pushProviders, err := loadPushProviders()
	if err != nil {
		logger.Error("worker push provider initialization failed", "error", err)
		os.Exit(2)
	}

	var mediaService *media.Service
	var dataRightsStore datarights.ArtifactStore
	if endpoint := strings.TrimRight(strings.TrimSpace(os.Getenv("MEDIA_S3_ENDPOINT")), "/"); endpoint != "" {
		accessKey, secretErr := appconfig.ReadSecret("MEDIA_S3_ACCESS_KEY")
		if secretErr != nil {
			logger.Error("worker media access-key configuration failed", "error", secretErr)
			os.Exit(2)
		}
		secretKey, secretErr := appconfig.ReadSecret("MEDIA_S3_SECRET_KEY")
		if secretErr != nil {
			logger.Error("worker media secret-key configuration failed", "error", secretErr)
			os.Exit(2)
		}
		store, storeErr := media.NewS3Store(media.S3Config{
			Endpoint:  endpoint,
			Bucket:    strings.TrimSpace(os.Getenv("MEDIA_S3_BUCKET")),
			Region:    strings.TrimSpace(os.Getenv("MEDIA_S3_REGION")),
			AccessKey: accessKey,
			SecretKey: secretKey,
		})
		if storeErr != nil {
			logger.Error("worker media object storage initialization failed", "error", storeErr)
			os.Exit(2)
		}
		dataRightsStore = store
		mediaService, err = media.NewService(media.Config{Pool: pool, Store: store})
		if err != nil {
			logger.Error("worker media service initialization failed", "error", err)
			os.Exit(2)
		}
	}

	dataRightsService, err := datarights.NewService(datarights.Config{
		Pool: pool, Hasher: password.NewDefaultHasher(), Store: dataRightsStore,
	})
	if err != nil {
		logger.Error("worker data rights initialization failed", "error", err)
		os.Exit(2)
	}

	logger.Info("worker started", "service", "dd-worker", "version", version)
	outboxTicker := time.NewTicker(500 * time.Millisecond)
	defer outboxTicker.Stop()
	mediaCleanupTicker := time.NewTicker(time.Minute)
	defer mediaCleanupTicker.Stop()
	dataRightsTicker := time.NewTicker(2 * time.Second)
	defer dataRightsTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			logger.Info("worker stopped", "service", "dd-worker", "version", version)
			return
		case <-outboxTicker.C:
			batchContext, batchCancel := context.WithTimeout(ctx, 5*time.Second)
			processed, dispatchErr := messagingService.DispatchOutbox(batchContext, 100)
			if dispatchErr == nil {
				var pushed int
				pushed, dispatchErr = pushService.DispatchJobs(batchContext, pushProviders, 100)
				if pushed > 0 {
					logger.Info("push batch dispatched", "service", "dd-worker", "jobs", pushed)
				}
			}
			batchCancel()
			if dispatchErr != nil {
				logger.Error("outbox/push dispatch failed", "service", "dd-worker", "error", dispatchErr)
				continue
			}
			if processed > 0 {
				logger.Info("outbox batch dispatched", "service", "dd-worker", "events", processed)
			}
		case <-dataRightsTicker.C:
			jobContext, jobCancel := context.WithTimeout(ctx, 2*time.Minute)
			exported := 0
			var rightsErr error
			if dataRightsStore != nil {
				exported, rightsErr = dataRightsService.ProcessExportJobs(jobContext, 2)
			}
			deleted := 0
			if rightsErr == nil {
				deleted, rightsErr = dataRightsService.ProcessDeletionJobs(jobContext, 2)
			}
			jobCancel()
			if rightsErr != nil {
				logger.Error("data rights job dispatch failed", "service", "dd-worker", "error", rightsErr)
				continue
			}
			if exported > 0 || deleted > 0 {
				logger.Info("data rights jobs processed", "service", "dd-worker", "exports", exported, "deletions", deleted)
			}
		case <-mediaCleanupTicker.C:
			cleanupContext, cleanupCancel := context.WithTimeout(ctx, 30*time.Second)
			packRemoved, cleanupErr := stickerService.CleanupUnusedPacks(
				cleanupContext,
				50,
				30*24*time.Hour,
			)
			mediaRemoved := 0
			exportRemoved := 0
			if cleanupErr == nil && dataRightsStore != nil {
				exportRemoved, cleanupErr = dataRightsService.CleanupExpiredExports(cleanupContext, 50)
			}
			if cleanupErr == nil && mediaService != nil {
				mediaRemoved, cleanupErr = mediaService.CleanupExpiredUploads(cleanupContext, 100)
			}
			if cleanupErr == nil && mediaService != nil {
				var managedRemoved int
				managedRemoved, cleanupErr = mediaService.CleanupOrphanedChatMedia(
					cleanupContext,
					50,
					30*24*time.Hour,
				)
				mediaRemoved += managedRemoved
			}
			cleanupCancel()
			if cleanupErr != nil {
				logger.Error("sticker/media cleanup failed", "service", "dd-worker", "error", cleanupErr)
				continue
			}
			if packRemoved > 0 || mediaRemoved > 0 || exportRemoved > 0 {
				logger.Info(
					"sticker/media cleanup completed",
					"service", "dd-worker",
					"sticker_packs", packRemoved,
					"media_objects", mediaRemoved,
					"data_exports", exportRemoved,
				)
			}
		}
	}
}

func loadPushProviders() (push.Providers, error) {
	providers := push.Providers{UnifiedPush: push.NewUnifiedPushProvider(push.UnifiedPushConfig{})}
	fcmJSON, err := appconfig.ReadSecret("FCM_SERVICE_ACCOUNT_JSON")
	if err != nil {
		return push.Providers{}, err
	}
	if strings.TrimSpace(fcmJSON) != "" {
		providers.FCM, err = push.NewFCMProvider(push.FCMConfig{ServiceAccountJSON: fcmJSON})
		if err != nil {
			return push.Providers{}, err
		}
	}
	apnsPrivateKey, err := appconfig.ReadSecret("APNS_PRIVATE_KEY")
	if err != nil {
		return push.Providers{}, err
	}
	keyID := strings.TrimSpace(os.Getenv("APNS_KEY_ID"))
	teamID := strings.TrimSpace(os.Getenv("APNS_TEAM_ID"))
	bundleID := strings.TrimSpace(os.Getenv("APNS_BUNDLE_ID"))
	if keyID != "" || teamID != "" || bundleID != "" || strings.TrimSpace(apnsPrivateKey) != "" {
		providers.APNS, err = push.NewAPNSProvider(push.APNSConfig{
			KeyID:         keyID,
			TeamID:        teamID,
			BundleID:      bundleID,
			PrivateKeyPEM: apnsPrivateKey,
		})
		if err != nil {
			return push.Providers{}, err
		}
	}
	return providers, nil
}
