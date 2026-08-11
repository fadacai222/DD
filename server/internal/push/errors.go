package push

import "errors"

var (
	ErrUnavailable         = errors.New("push service unavailable")
	ErrInvalidInput        = errors.New("invalid push input")
	ErrForbidden           = errors.New("push operation forbidden")
	ErrConflict            = errors.New("push endpoint conflict")
	ErrNotFound            = errors.New("push endpoint not found")
	ErrProviderUnavailable = errors.New("push provider unavailable")
	ErrRetryable           = errors.New("retryable push provider error")
)
