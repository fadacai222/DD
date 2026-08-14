package account

import (
	"errors"
	"strings"
	"sync/atomic"
)

var (
	ErrRegistrationModeInvalid     = errors.New("registration mode is invalid")
	ErrRegistrationOpenUnavailable = errors.New("open registration dependencies are unavailable")
)

type RegistrationModeSource interface {
	Mode() string
}

type RegistrationController struct {
	mode          atomic.Value
	openAvailable bool
}

func NewRegistrationController(initialMode string, openAvailable bool) (*RegistrationController, error) {
	mode := normalizeRuntimeRegistrationMode(initialMode)
	if mode == "" {
		return nil, ErrRegistrationModeInvalid
	}
	controller := &RegistrationController{openAvailable: openAvailable}
	if mode == "open" && !openAvailable {
		return nil, ErrRegistrationOpenUnavailable
	}
	controller.mode.Store(mode)
	return controller, nil
}

func (controller *RegistrationController) Mode() string {
	if controller == nil {
		return "closed"
	}
	value := controller.mode.Load()
	if value == nil {
		return "closed"
	}
	return value.(string)
}

func (controller *RegistrationController) OpenAvailable() bool {
	return controller != nil && controller.openAvailable
}

func (controller *RegistrationController) ValidateMode(raw string) error {
	mode := strings.ToLower(strings.TrimSpace(raw))
	if mode != "open" && mode != "closed" {
		return ErrRegistrationModeInvalid
	}
	if mode == "open" && !controller.OpenAvailable() {
		return ErrRegistrationOpenUnavailable
	}
	return nil
}

func (controller *RegistrationController) SetMode(raw string) error {
	if err := controller.ValidateMode(raw); err != nil {
		return err
	}
	controller.mode.Store(strings.ToLower(strings.TrimSpace(raw)))
	return nil
}

func normalizeRuntimeRegistrationMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "open", "invite", "approval", "closed":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return ""
	}
}
