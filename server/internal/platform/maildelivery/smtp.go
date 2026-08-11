package maildelivery

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	netmail "net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"time"
)

type Observer interface {
	ObserveSMTP(duration time.Duration, err error)
}

type SMTPConfig struct {
	Host       string
	Port       int
	From       string
	Username   string
	Password   string
	RequireTLS bool
	Observer   Observer
}

type SMTPMailer struct {
	config       SMTPConfig
	envelopeFrom string
	fromHeader   string
	observer     Observer
}

func NewSMTPMailer(config SMTPConfig) (*SMTPMailer, error) {
	config.Host = strings.TrimSpace(config.Host)
	config.From = strings.TrimSpace(config.From)
	config.Username = strings.TrimSpace(config.Username)
	if config.Host == "" || strings.ContainsAny(config.Host, "\r\n") {
		return nil, errors.New("SMTP host is invalid")
	}
	if config.Port < 1 || config.Port > 65535 {
		return nil, errors.New("SMTP port is invalid")
	}
	from, err := netmail.ParseAddress(config.From)
	if err != nil || from.Address == "" || strings.ContainsAny(config.From, "\r\n") {
		return nil, errors.New("SMTP from address is invalid")
	}
	if config.Username != "" && config.Password == "" {
		return nil, errors.New("SMTP password is required when username is configured")
	}
	return &SMTPMailer{
		config:       config,
		envelopeFrom: from.Address,
		fromHeader:   (&netmail.Address{Name: "DD", Address: from.Address}).String(),
		observer:     config.Observer,
	}, nil
}

func (mailer *SMTPMailer) SendVerificationCode(ctx context.Context, to, purpose, code string) (err error) {
	started := time.Now()
	defer func() {
		if mailer.observer != nil {
			mailer.observer.ObserveSMTP(time.Since(started), err)
		}
	}()
	message, err := mailer.buildVerificationMessage(to, purpose, code)
	if err != nil {
		return err
	}
	recipient, err := netmail.ParseAddress(to)
	if err != nil || recipient.Address != to || strings.ContainsAny(to, "\r\n") {
		return errors.New("recipient address is invalid")
	}

	address := net.JoinHostPort(mailer.config.Host, strconv.Itoa(mailer.config.Port))
	dialer := net.Dialer{Timeout: 10 * time.Second}
	connection, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return fmt.Errorf("connect SMTP server: %w", err)
	}
	defer connection.Close()
	deadline := time.Now().Add(15 * time.Second)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	_ = connection.SetDeadline(deadline)

	client, err := smtp.NewClient(connection, mailer.config.Host)
	if err != nil {
		return fmt.Errorf("start SMTP client: %w", err)
	}
	defer client.Close()

	tlsActive := false
	if ok, _ := client.Extension("STARTTLS"); ok {
		if err := client.StartTLS(&tls.Config{
			ServerName: mailer.config.Host,
			MinVersion: tls.VersionTLS12,
		}); err != nil {
			return fmt.Errorf("SMTP STARTTLS failed: %w", err)
		}
		tlsActive = true
	} else if mailer.config.RequireTLS {
		return errors.New("SMTP server does not advertise STARTTLS")
	}

	if mailer.config.Username != "" {
		if !tlsActive {
			return errors.New("refusing SMTP authentication over plaintext transport")
		}
		auth := smtp.PlainAuth("", mailer.config.Username, mailer.config.Password, mailer.config.Host)
		if err := client.Auth(auth); err != nil {
			return fmt.Errorf("SMTP authentication failed: %w", err)
		}
	}
	if err := client.Mail(mailer.envelopeFrom); err != nil {
		return fmt.Errorf("SMTP MAIL FROM failed: %w", err)
	}
	if err := client.Rcpt(recipient.Address); err != nil {
		return fmt.Errorf("SMTP RCPT TO failed: %w", err)
	}
	writer, err := client.Data()
	if err != nil {
		return fmt.Errorf("SMTP DATA failed: %w", err)
	}
	if _, err := io.WriteString(writer, message); err != nil {
		_ = writer.Close()
		return fmt.Errorf("write SMTP message: %w", err)
	}
	if err := writer.Close(); err != nil {
		return fmt.Errorf("finish SMTP message: %w", err)
	}
	if err := client.Quit(); err != nil {
		return fmt.Errorf("SMTP QUIT failed: %w", err)
	}
	return nil
}

func (mailer *SMTPMailer) buildVerificationMessage(to, purpose, code string) (string, error) {
	if strings.ContainsAny(to, "\r\n") || strings.ContainsAny(code, "\r\n") || strings.ContainsAny(purpose, "\r\n") {
		return "", errors.New("mail field contains newline")
	}
	recipient, err := netmail.ParseAddress(to)
	if err != nil || recipient.Address != to {
		return "", errors.New("recipient address is invalid")
	}
	if len(code) != 6 {
		return "", errors.New("verification code must contain 6 digits")
	}
	for _, character := range code {
		if character < '0' || character > '9' {
			return "", errors.New("verification code contains non-digit")
		}
	}

	subject := "DD 邮箱验证码"
	if purpose == "PASSWORD_RESET" {
		subject = "DD 密码重置验证码"
	}
	body := "你的 DD 验证码是：" + code + "\r\n\r\n验证码有效期较短，请勿转发给他人。若非本人操作，请忽略此邮件。\r\n"

	var builder strings.Builder
	writer := bufio.NewWriter(&builder)
	_, _ = fmt.Fprintf(writer, "From: %s\r\n", mailer.fromHeader)
	_, _ = fmt.Fprintf(writer, "To: %s\r\n", recipient.Address)
	_, _ = fmt.Fprintf(writer, "Subject: %s\r\n", mime.QEncoding.Encode("utf-8", subject))
	_, _ = fmt.Fprint(writer, "MIME-Version: 1.0\r\n")
	_, _ = fmt.Fprint(writer, "Content-Type: text/plain; charset=UTF-8\r\n")
	_, _ = fmt.Fprint(writer, "Content-Transfer-Encoding: 8bit\r\n")
	_, _ = fmt.Fprint(writer, "\r\n")
	_, _ = fmt.Fprint(writer, body)
	_ = writer.Flush()
	return builder.String(), nil
}
