package transcription

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
)

func (service *Service) runClaimed(ctx context.Context, job claimedJob) {
	principal := account.Principal{UserID: job.RequesterID}
	voice, err := service.loadAuthorizedVoice(ctx, principal, job.MessageID)
	if err != nil {
		service.finishFailure(ctx, job, "MESSAGE_UNAVAILABLE", false)
		return
	}
	downloadURL, _, err := service.media.CreateDownloadURL(ctx, principal, voice.MediaID)
	if err != nil {
		service.finishRetry(ctx, job, "MEDIA_FETCH_TEMPORARY")
		return
	}
	audio, err := service.download(ctx, downloadURL)
	if err != nil {
		service.finishRetry(ctx, job, "MEDIA_FETCH_TEMPORARY")
		return
	}
	result, err := service.provider.Transcribe(ctx, ProviderInput{
		FileName: voice.FileName,
		MIMEType: voice.MIMEType,
		Audio: audio,
	})
	if err != nil {
		if errors.Is(err, ErrProviderTemp) {
			service.finishRetry(ctx, job, "PROVIDER_TEMPORARY")
		} else {
			service.finishFailure(ctx, job, "PROVIDER_PERMANENT", false)
		}
		return
	}
	if _, err := service.loadAuthorizedVoice(ctx, principal, job.MessageID); err != nil {
		service.finishFailure(ctx, job, "MESSAGE_UNAVAILABLE", false)
		return
	}
	now := service.now().UTC()
	_, _ = service.pool.Exec(ctx, `
		UPDATE voice_transcriptions
		SET status='COMPLETED',transcript=$2,language=NULLIF($3,''),model=NULLIF($4,''),error_category=NULL,
		    retryable=false,lease_expires_at=NULL,updated_at=$5,completed_at=$5
		WHERE id=$1 AND status='RUNNING'
	`, job.ID, strings.TrimSpace(result.Transcript), strings.TrimSpace(result.Language), strings.TrimSpace(result.Model), now)
}

func (service *Service) download(ctx context.Context, rawURL string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil { return nil, err }
	response, err := service.httpClient.Do(request)
	if err != nil { return nil, err }
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return nil, fmt.Errorf("media download http %d", response.StatusCode)
	}
	payload, err := io.ReadAll(io.LimitReader(response.Body, maxVoiceBytes+1))
	if err != nil || int64(len(payload)) > maxVoiceBytes || len(payload) == 0 {
		return nil, errors.New("voice media download invalid")
	}
	return payload, nil
}
