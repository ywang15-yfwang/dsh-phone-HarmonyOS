package main

// control_probe.go —— 控制平面可达性探测。
//
// 逐字取自 _refs\Tailscale-OHOS\native\go_bridge\control_probe.go
// （flypigJ/Tailscale-OHOS@fd49406f），未改动逻辑；用途是在真正登录之前先分清
// "是网络不通" 还是 "是证书/控制平面不通"，给 App 的四态与失败提示可读依据。
//
// 注意：只做 DNS + TCP + TLS 握手，不发任何凭据，也不读任何业务数据。

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

const controlProbeHost = "controlplane.tailscale.com"

type controlProbeController struct {
	mu      sync.Mutex
	running bool
	result  string
}

var harmonyControlProbe controlProbeController

func (p *controlProbeController) startOrStatus() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.running {
		return "OK | control probe running"
	}
	if p.result != "" {
		result := p.result
		p.result = ""
		return result
	}
	p.running = true
	go p.run()
	return "OK | control probe starting"
}

func (p *controlProbeController) run() {
	result := runControlProbe()
	p.mu.Lock()
	p.running = false
	p.result = result
	p.mu.Unlock()
}

func runControlProbe() string {
	rootCount := 0
	rootPool, rootErr := x509.SystemCertPool()
	if rootPool != nil {
		rootCount = len(rootPool.Subjects())
	}
	if rootErr != nil {
		return fmt.Sprintf(
			"FAILED | stage=roots | category=%s | roots=%d",
			classifyControlProbeError(rootErr), rootCount)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	if _, err := net.DefaultResolver.LookupHost(ctx, controlProbeHost); err != nil {
		return fmt.Sprintf(
			"FAILED | stage=dns | category=%s | roots=%d",
			classifyControlProbeError(err), rootCount)
	}

	dialer := &net.Dialer{Timeout: 5 * time.Second}
	address := net.JoinHostPort(controlProbeHost, "443")
	tcpConn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return fmt.Sprintf(
			"FAILED | stage=tcp | category=%s | roots=%d | dns=true",
			classifyControlProbeError(err), rootCount)
	}
	tlsConn := tls.Client(tcpConn, &tls.Config{
		ServerName: controlProbeHost,
		MinVersion: tls.VersionTLS12,
	})
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = tlsConn.Close()
		return fmt.Sprintf(
			"FAILED | stage=tls | category=%s | roots=%d | dns=true | tcp=true",
			classifyControlProbeError(err), rootCount)
	}
	_ = tlsConn.Close()
	return fmt.Sprintf(
		"OK | strictTLS=true | roots=%d | dns=true | tcp=true",
		rootCount)
}

func classifyControlProbeError(err error) string {
	var unknownAuthority x509.UnknownAuthorityError
	if errors.As(err, &unknownAuthority) {
		return "x509-unknown-authority"
	}
	var hostnameError x509.HostnameError
	if errors.As(err, &hostnameError) {
		return "x509-hostname"
	}
	var certificateInvalid x509.CertificateInvalidError
	if errors.As(err, &certificateInvalid) {
		return "x509-invalid-certificate"
	}
	var dnsError *net.DNSError
	if errors.As(err, &dnsError) {
		return "dns-error"
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return "network-timeout"
	}
	lower := strings.ToLower(err.Error())
	switch {
	case strings.Contains(lower, "permission denied"),
		strings.Contains(lower, "operation not permitted"):
		return "network-permission-denied"
	case strings.Contains(lower, "network is unreachable"),
		strings.Contains(lower, "no route to host"):
		return "network-unreachable"
	case strings.Contains(lower, "connection refused"),
		strings.Contains(lower, "connection reset"):
		return "connection-error"
	case strings.Contains(lower, "certificate"), strings.Contains(lower, "x509"):
		return "certificate-error"
	default:
		return "other"
	}
}
