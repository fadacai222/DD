package media

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

type ObjectStore interface {
	PresignPut(key, contentType, sha256Hex string, ttl time.Duration) (string, map[string]string, time.Time, error)
	PresignGet(key string, ttl time.Duration) (string, time.Time, error)
	Stat(ctx context.Context, key string) (ObjectInfo, error)
	Delete(ctx context.Context, key string) error
}

type S3Config struct {
	Endpoint   string
	Bucket     string
	Region     string
	AccessKey  string
	SecretKey  string
	HTTPClient *http.Client
	Now        func() time.Time
}

type S3Store struct {
	endpoint   *url.URL
	bucket     string
	region     string
	accessKey  string
	secretKey  string
	httpClient *http.Client
	now        func() time.Time
}

func NewS3Store(config S3Config) (*S3Store, error) {
	endpoint, err := url.Parse(strings.TrimRight(strings.TrimSpace(config.Endpoint), "/"))
	if err != nil || endpoint.Host == "" || (endpoint.Scheme != "http" && endpoint.Scheme != "https") || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" {
		return nil, errors.New("media S3 endpoint must be an http(s) origin or path prefix")
	}
	bucket := strings.TrimSpace(config.Bucket)
	if bucket == "" || strings.ContainsAny(bucket, "/\\?#") {
		return nil, errors.New("media S3 bucket is invalid")
	}
	if strings.TrimSpace(config.AccessKey) == "" || strings.TrimSpace(config.SecretKey) == "" {
		return nil, errors.New("media S3 credentials are required")
	}
	region := strings.TrimSpace(config.Region)
	if region == "" {
		region = "us-east-1"
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	client := config.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &S3Store{
		endpoint:   endpoint,
		bucket:     bucket,
		region:     region,
		accessKey:  strings.TrimSpace(config.AccessKey),
		secretKey:  config.SecretKey,
		httpClient: client,
		now:        now,
	}, nil
}

func (store *S3Store) PresignPut(key, contentType, sha256Hex string, ttl time.Duration) (string, map[string]string, time.Time, error) {
	if ttl <= 0 || ttl > 15*time.Minute {
		return "", nil, time.Time{}, errors.New("presigned upload TTL must be between 1s and 15m")
	}
	contentType = strings.TrimSpace(strings.ToLower(contentType))
	sha256Hex = strings.TrimSpace(strings.ToLower(sha256Hex))
	checksumBytes, err := hex.DecodeString(sha256Hex)
	if contentType == "" || err != nil || len(checksumBytes) != sha256.Size {
		return "", nil, time.Time{}, ErrInvalidInput
	}
	checksum := base64.StdEncoding.EncodeToString(checksumBytes)
	headers := map[string]string{
		"Content-Type":          contentType,
		"x-amz-checksum-sha256": checksum,
	}
	signed, expiresAt, err := store.presign(http.MethodPut, key, ttl, headers)
	return signed, headers, expiresAt, err
}

func (store *S3Store) PresignGet(key string, ttl time.Duration) (string, time.Time, error) {
	if ttl <= 0 || ttl > 15*time.Minute {
		return "", time.Time{}, errors.New("presigned download TTL must be between 1s and 15m")
	}
	return store.presign(http.MethodGet, key, ttl, nil)
}

func (store *S3Store) Stat(ctx context.Context, key string) (ObjectInfo, error) {
	request, err := store.signedRequest(ctx, http.MethodHead, key)
	if err != nil {
		return ObjectInfo{}, err
	}
	response, err := store.httpClient.Do(request)
	if err != nil {
		return ObjectInfo{}, fmt.Errorf("stat media object: %w", err)
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	if response.StatusCode == http.StatusNotFound {
		return ObjectInfo{}, ErrNotFound
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return ObjectInfo{}, fmt.Errorf("stat media object: storage returned %d", response.StatusCode)
	}
	size, err := strconv.ParseInt(response.Header.Get("Content-Length"), 10, 64)
	if err != nil || size < 0 {
		return ObjectInfo{}, errors.New("stat media object: invalid content length")
	}
	checksumHex := ""
	if rawChecksum := strings.TrimSpace(response.Header.Get("X-Amz-Checksum-Sha256")); rawChecksum != "" {
		checksumBytes, decodeErr := base64.StdEncoding.DecodeString(rawChecksum)
		if decodeErr != nil || len(checksumBytes) != sha256.Size {
			return ObjectInfo{}, errors.New("stat media object: invalid SHA-256 checksum")
		}
		checksumHex = hex.EncodeToString(checksumBytes)
	}
	return ObjectInfo{
		Size:        size,
		ContentType: strings.ToLower(strings.TrimSpace(strings.Split(response.Header.Get("Content-Type"), ";")[0])),
		SHA256:      checksumHex,
		ETag:        strings.Trim(response.Header.Get("ETag"), "\""),
	}, nil
}

func (store *S3Store) Delete(ctx context.Context, key string) error {
	request, err := store.signedRequest(ctx, http.MethodDelete, key)
	if err != nil {
		return err
	}
	response, err := store.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("delete media object: %w", err)
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	if response.StatusCode == http.StatusNotFound || (response.StatusCode >= 200 && response.StatusCode < 300) {
		return nil
	}
	return fmt.Errorf("delete media object: storage returned %d", response.StatusCode)
}

func (store *S3Store) presign(method, key string, ttl time.Duration, requestHeaders map[string]string) (string, time.Time, error) {
	now := store.now().UTC()
	expiresAt := now.Add(ttl)
	objectURL, err := store.objectURL(key)
	if err != nil {
		return "", time.Time{}, err
	}
	date := now.Format("20060102")
	amzDate := now.Format("20060102T150405Z")
	scope := date + "/" + store.region + "/s3/aws4_request"
	canonicalHeaders, signedHeaders := canonicalPresignHeaders(objectURL.Host, requestHeaders)
	query := map[string]string{
		"X-Amz-Algorithm":     "AWS4-HMAC-SHA256",
		"X-Amz-Credential":    store.accessKey + "/" + scope,
		"X-Amz-Date":          amzDate,
		"X-Amz-Expires":       strconv.FormatInt(int64(ttl/time.Second), 10),
		"X-Amz-SignedHeaders": signedHeaders,
	}
	canonicalQuery := canonicalQueryString(query)
	canonicalRequest := strings.Join([]string{
		method,
		awsCanonicalPath(objectURL.EscapedPath()),
		canonicalQuery,
		canonicalHeaders,
		signedHeaders,
		"UNSIGNED-PAYLOAD",
	}, "\n")
	requestHash := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(requestHash[:])
	signature := hex.EncodeToString(hmacSHA256(store.signingKey(date), []byte(stringToSign)))
	query["X-Amz-Signature"] = signature
	objectURL.RawQuery = canonicalQueryString(query)
	return objectURL.String(), expiresAt, nil
}

func (store *S3Store) signedRequest(ctx context.Context, method, key string) (*http.Request, error) {
	now := store.now().UTC()
	objectURL, err := store.objectURL(key)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, method, objectURL.String(), nil)
	if err != nil {
		return nil, err
	}
	date := now.Format("20060102")
	amzDate := now.Format("20060102T150405Z")
	emptyHash := sha256.Sum256(nil)
	payloadHash := hex.EncodeToString(emptyHash[:])
	request.Header.Set("X-Amz-Date", amzDate)
	request.Header.Set("X-Amz-Content-Sha256", payloadHash)
	canonicalHeaders := "host:" + objectURL.Host + "\n" + "x-amz-content-sha256:" + payloadHash + "\n" + "x-amz-date:" + amzDate + "\n"
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"
	canonicalRequest := strings.Join([]string{
		method,
		awsCanonicalPath(objectURL.EscapedPath()),
		"",
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")
	requestHash := sha256.Sum256([]byte(canonicalRequest))
	scope := date + "/" + store.region + "/s3/aws4_request"
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(requestHash[:])
	signature := hex.EncodeToString(hmacSHA256(store.signingKey(date), []byte(stringToSign)))
	request.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+store.accessKey+"/"+scope+", SignedHeaders="+signedHeaders+", Signature="+signature)
	return request, nil
}

func (store *S3Store) objectURL(key string) (*url.URL, error) {
	key = strings.Trim(strings.TrimSpace(key), "/")
	if key == "" || strings.Contains(key, "..") || strings.ContainsAny(key, "\\?#") {
		return nil, ErrInvalidInput
	}
	copyURL := *store.endpoint
	basePath := strings.TrimRight(copyURL.Path, "/")
	segments := strings.Split(key, "/")
	for index, segment := range segments {
		segments[index] = url.PathEscape(segment)
	}
	copyURL.Path = basePath + "/" + url.PathEscape(store.bucket) + "/" + strings.Join(segments, "/")
	copyURL.RawPath = ""
	return &copyURL, nil
}

func (store *S3Store) signingKey(date string) []byte {
	dateKey := hmacSHA256([]byte("AWS4"+store.secretKey), []byte(date))
	regionKey := hmacSHA256(dateKey, []byte(store.region))
	serviceKey := hmacSHA256(regionKey, []byte("s3"))
	return hmacSHA256(serviceKey, []byte("aws4_request"))
}

func hmacSHA256(key, data []byte) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(data)
	return mac.Sum(nil)
}

func canonicalPresignHeaders(host string, headers map[string]string) (string, string) {
	values := map[string]string{"host": strings.TrimSpace(host)}
	for key, value := range headers {
		name := strings.ToLower(strings.TrimSpace(key))
		if name == "" || name == "host" {
			continue
		}
		values[name] = strings.Join(strings.Fields(value), " ")
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var canonical strings.Builder
	for _, key := range keys {
		canonical.WriteString(key)
		canonical.WriteByte(':')
		canonical.WriteString(values[key])
		canonical.WriteByte('\n')
	}
	return canonical.String(), strings.Join(keys, ";")
}

func canonicalQueryString(values map[string]string) string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, awsEncode(key)+"="+awsEncode(values[key]))
	}
	return strings.Join(parts, "&")
}

func awsEncode(value string) string {
	encoded := url.QueryEscape(value)
	encoded = strings.ReplaceAll(encoded, "+", "%20")
	encoded = strings.ReplaceAll(encoded, "%7E", "~")
	return encoded
}

func awsCanonicalPath(path string) string {
	if path == "" {
		return "/"
	}
	return path
}
