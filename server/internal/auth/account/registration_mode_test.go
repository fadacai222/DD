package account

import (
	"errors"
	"testing"
)

func TestRegistrationControllerRuntimePolicy(t *testing.T) {
	controller, err := NewRegistrationController("closed", true)
	if err != nil {
		t.Fatal(err)
	}
	if controller.Mode() != "closed" || !controller.OpenAvailable() {
		t.Fatalf("initial controller=%q available=%v", controller.Mode(), controller.OpenAvailable())
	}
	if err := controller.SetMode("OPEN"); err != nil {
		t.Fatalf("open: %v", err)
	}
	if controller.Mode() != "open" {
		t.Fatalf("mode=%q", controller.Mode())
	}
	if err := controller.SetMode("invite"); !errors.Is(err, ErrRegistrationModeInvalid) {
		t.Fatalf("invite runtime error=%v", err)
	}
}

func TestRegistrationControllerRejectsOpenWithoutDependencies(t *testing.T) {
	controller, err := NewRegistrationController("closed", false)
	if err != nil {
		t.Fatal(err)
	}
	if err := controller.SetMode("open"); !errors.Is(err, ErrRegistrationOpenUnavailable) {
		t.Fatalf("open error=%v", err)
	}
	if controller.Mode() != "closed" {
		t.Fatalf("mode changed to %q", controller.Mode())
	}
	if _, err := NewRegistrationController("open", false); !errors.Is(err, ErrRegistrationOpenUnavailable) {
		t.Fatalf("initial open error=%v", err)
	}
}
