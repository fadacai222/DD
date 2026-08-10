package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/qrcode"
	"github.com/google/uuid"
)

type QRService interface {
	UserPayload(uuid.UUID) (qrcode.Payload, error)
	CreateGroupInvite(context.Context, account.Principal, uuid.UUID, qrcode.CreateGroupInviteInput) (qrcode.GroupInvite, error)
	RevokeGroupInvite(context.Context, account.Principal, uuid.UUID) error
	RedeemGroupInvite(context.Context, account.Principal, string) (qrcode.GroupRedeemResult, []uuid.UUID, error)
	CreateLogin(context.Context, qrcode.CreateLoginInput) (qrcode.LoginSession, error)
	PollLogin(context.Context, string) (qrcode.LoginSession, error)
	ScanLogin(context.Context, account.Principal, string) (qrcode.LoginSession, error)
	ConfirmLogin(context.Context, account.Principal, string, bool) (qrcode.LoginSession, error)
	ConsumeLogin(context.Context, string) (qrcode.ConsumeLoginResult, error)
}

type qrNonceRequest struct {
	Nonce string `json:"nonce"`
}

type qrGroupInviteRequest struct {
	GroupID          string `json:"groupId"`
	ExpiresInSeconds int    `json:"expiresInSeconds"`
	MaxUses          *int   `json:"maxUses,omitempty"`
}

type qrLoginConfirmRequest struct {
	Nonce    string `json:"nonce"`
	Approved bool   `json:"approved"`
}

func (s *server) handleMyQR(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}
	principal, ok := s.requireQRPrincipal(response, request)
	if !ok {
		return
	}
	payload, err := s.qr.UserPayload(principal.UserID)
	if err != nil {
		s.writeQRError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, payload)
}

func (s *server) handleGroupQRInvites(response http.ResponseWriter, request *http.Request) {
	principal, ok := s.requireQRPrincipal(response, request)
	if !ok {
		return
	}
	if request.URL.Path == "/api/v1/group-qr-invites" {
		if request.Method != http.MethodPost {
			methodNotAllowed(response, http.MethodPost)
			return
		}
		if !requireJSON(response, request) {
			return
		}
		var raw qrGroupInviteRequest
		if err := decodeSingleJSON(response, request, &raw); err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_QR_REQUEST", err.Error())
			return
		}
		groupID, err := uuid.Parse(strings.TrimSpace(raw.GroupID))
		if err != nil {
			writeAPIError(response, http.StatusBadRequest, "INVALID_QR_REQUEST", "groupId must be a UUID")
			return
		}
		invite, err := s.qr.CreateGroupInvite(request.Context(), principal, groupID, qrcode.CreateGroupInviteInput{
			ExpiresInSeconds: raw.ExpiresInSeconds,
			MaxUses:          raw.MaxUses,
		})
		if err != nil {
			s.writeQRError(response, request, err)
			return
		}
		writeSuccess(response, http.StatusCreated, invite)
		return
	}
	if request.Method != http.MethodDelete {
		methodNotAllowed(response, http.MethodDelete)
		return
	}
	rawID := strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/v1/group-qr-invites/"), "/")
	inviteID, err := uuid.Parse(rawID)
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_QR_REQUEST", "inviteId must be a UUID")
		return
	}
	if err := s.qr.RevokeGroupInvite(request.Context(), principal, inviteID); err != nil {
		s.writeQRError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, map[string]any{"revoked": true})
}

func (s *server) handleGroupQRRedeem(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requireQRPrincipal(response, request)
	if !ok {
		return
	}
	var input qrNonceRequest
	if !decodeQRJSON(response, request, &input) {
		return
	}
	result, recipients, err := s.qr.RedeemGroupInvite(request.Context(), principal, input.Nonce)
	if err != nil {
		s.writeQRError(response, request, err)
		return
	}
	if len(recipients) > 0 {
		s.publishEventAvailable(recipients, "group-qr-redeemed")
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleQRLoginCreate(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input qrcode.CreateLoginInput
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_QR_REQUEST", err.Error())
		return
	}
	result, err := s.qr.CreateLogin(request.Context(), input)
	if err != nil {
		s.writeQRError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusCreated, result)
}

func (s *server) handleQRLoginStatus(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	var input qrNonceRequest
	if !decodeQRJSON(response, request, &input) {
		return
	}
	result, err := s.qr.PollLogin(request.Context(), input.Nonce)
	if err != nil {
		s.writeQRError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleQRLoginScan(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requireQRPrincipal(response, request)
	if !ok {
		return
	}
	var input qrNonceRequest
	if !decodeQRJSON(response, request, &input) {
		return
	}
	result, err := s.qr.ScanLogin(request.Context(), principal, input.Nonce)
	if err != nil {
		s.writeQRError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleQRLoginConfirm(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	principal, ok := s.requireQRPrincipal(response, request)
	if !ok {
		return
	}
	if !requireJSON(response, request) {
		return
	}
	var input qrLoginConfirmRequest
	if err := decodeSingleJSON(response, request, &input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_QR_REQUEST", err.Error())
		return
	}
	result, err := s.qr.ConfirmLogin(request.Context(), principal, input.Nonce, input.Approved)
	if err != nil {
		s.writeQRError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func (s *server) handleQRLoginConsume(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		methodNotAllowed(response, http.MethodPost)
		return
	}
	var input qrNonceRequest
	if !decodeQRJSON(response, request, &input) {
		return
	}
	result, err := s.qr.ConsumeLogin(request.Context(), input.Nonce)
	if err != nil {
		s.writeQRError(response, request, err)
		return
	}
	writeSuccess(response, http.StatusOK, result)
}

func decodeQRJSON(response http.ResponseWriter, request *http.Request, output any) bool {
	if !requireJSON(response, request) {
		return false
	}
	if err := decodeSingleJSON(response, request, output); err != nil {
		writeAPIError(response, http.StatusBadRequest, "INVALID_QR_REQUEST", err.Error())
		return false
	}
	return true
}

func (s *server) requireQRPrincipal(response http.ResponseWriter, request *http.Request) (account.Principal, bool) {
	if s.qr == nil {
		writeAPIError(response, http.StatusServiceUnavailable, "QR_SERVICE_UNAVAILABLE", "QR service is not configured")
		return account.Principal{}, false
	}
	return s.requirePrincipal(response, request)
}

func (s *server) writeQRError(response http.ResponseWriter, request *http.Request, err error) {
	switch {
	case errors.Is(err, qrcode.ErrInvalid):
		writeAPIError(response, http.StatusBadRequest, "INVALID_QR_REQUEST", "QR request is invalid")
	case errors.Is(err, qrcode.ErrNotFound):
		writeAPIError(response, http.StatusNotFound, "QR_NOT_FOUND", "QR credential was not found")
	case errors.Is(err, qrcode.ErrForbidden):
		writeAPIError(response, http.StatusForbidden, "QR_FORBIDDEN", "QR operation is not allowed")
	case errors.Is(err, qrcode.ErrExpired):
		writeAPIError(response, http.StatusGone, "QR_EXPIRED", "QR credential has expired")
	case errors.Is(err, qrcode.ErrConsumed):
		writeAPIError(response, http.StatusGone, "QR_CONSUMED", "QR login has already been consumed")
	case errors.Is(err, qrcode.ErrRejected):
		writeAPIError(response, http.StatusConflict, "QR_LOGIN_REJECTED", "QR login was rejected")
	case errors.Is(err, qrcode.ErrConflict):
		writeAPIError(response, http.StatusConflict, "QR_STATE_CONFLICT", "QR state does not allow this operation")
	case errors.Is(err, qrcode.ErrUnavailable):
		writeAPIError(response, http.StatusServiceUnavailable, "QR_SERVICE_UNAVAILABLE", "QR service is unavailable")
	default:
		s.logger.Error("qr request failed", "requestId", response.Header().Get(requestIDHeader), "path", request.URL.Path, "error", err)
		writeAPIError(response, http.StatusInternalServerError, "QR_INTERNAL_ERROR", "QR request failed")
	}
}
