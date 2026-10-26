package main

// peer_request_run.go —— 上面那 5 个动作背后的**唯一一条执行流**：
//   dial(netstack) → 发请求头 → 流式发请求体（带背压）→ 读响应头 → 流式读响应体（带背压）→ eof
//
// 与 peer_request.go 的分工：那边是"对外形态 + 白名单 + 句柄表"，这边是"网络动作"。
// 契约：harmonyos-app-toolchain\docs\p2-kernel-request-export-contract-draft.md

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"tailscale.com/tsnet"
)

func marshalJSON(value any) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		return `{"ok":false,"code":"invalid_request","message":"marshal failed"}`
	}
	return string(encoded)
}

// runPeerRequest 是句柄的执行流；出错一律走 h.fail，**绝不在手机侧开任何监听**。
func (b *backendController) runPeerRequest(
	ctx context.Context, h *peerRequestHandle, server *tsnet.Server,
	req peerRequestOpenRequest, dialAddr string, port int,
) {
	defer func() {
		if recovered := recover(); recovered != nil {
			h.fail("upstream_reset", "recv", fmt.Errorf("panic: %v", recovered))
		}
	}()

	// ---- 1) 经 netstack 建连（tsnet.go:731-734 保证 tailnet 目的地走内嵌 netstack）
	dialCtx, dialCancel := context.WithTimeout(ctx, time.Duration(req.ConnectTimeoutMs)*time.Millisecond)
	conn, err := server.Dial(dialCtx, "tcp", net.JoinHostPort(dialAddr, strconv.Itoa(port)))
	dialCancel()
	if err != nil {
		h.fail(classifyDialError(err, ctx), "dial", err)
		return
	}

	h.mu.Lock()
	h.conn = conn
	if h.state == "closed" { // open 之后立刻被 close 的竞态
		h.mu.Unlock()
		_ = conn.Close()
		return
	}
	h.state = "sending"
	h.mu.Unlock()

	// ---- 2) 请求头（Host 由 requestHost 定，默认回环形式 —— 契约 §4）
	if err := writeRequestHead(conn, req, port); err != nil {
		h.fail("upstream_reset", "send", err)
		_ = conn.Close()
		return
	}

	// ---- 3) 请求体：流式 + 背压（契约 §5）
	if req.HasBody {
		if err := streamUploadBody(ctx, h, conn, req); err != nil {
			if h.currentState() != "closed" {
				h.fail(classifyWriteError(err), "send", err)
			}
			_ = conn.Close()
			return
		}
	}
	if h.currentState() == "closed" {
		_ = conn.Close()
		return
	}
	h.setState("awaiting-response", "", "", "")

	// ---- 4) 响应头
	_ = conn.SetReadDeadline(readDeadline(req, time.Duration(req.ResponseHeaderMs)*time.Millisecond))
	reader := bufio.NewReaderSize(conn, 64<<10)
	resp, err := http.ReadResponse(reader, &http.Request{Method: req.Method})
	if err != nil {
		code := "upstream_reset"
		if isTimeoutError(err) {
			code = "response_timeout"
		}
		if h.currentState() != "closed" {
			h.fail(code, "recv", err)
		}
		_ = conn.Close()
		return
	}

	h.mu.Lock()
	if h.state == "closed" {
		h.mu.Unlock()
		_ = resp.Body.Close()
		_ = conn.Close()
		return
	}
	h.status = resp.StatusCode
	h.headers = flattenHeader(resp.Header)
	h.body = resp.Body
	h.state = "streaming"
	h.respCond.Broadcast()
	h.mu.Unlock()

	// ---- 5) 响应体：边读边给，缓冲到高水位就停（背压，不丢数据）
	buffer := make([]byte, 64<<10)
	for {
		h.mu.Lock()
		for h.respBuf.Len() >= responseHighWater && h.state != "closed" {
			h.respCond.Wait()
		}
		if h.state == "closed" {
			h.mu.Unlock()
			_ = resp.Body.Close()
			_ = conn.Close()
			return
		}
		h.mu.Unlock()

		_ = conn.SetReadDeadline(readDeadline(req, time.Duration(req.IdleTimeoutMs)*time.Millisecond))
		n, readErr := resp.Body.Read(buffer)
		if n > 0 {
			h.mu.Lock()
			h.respBuf.Write(buffer[:n])
			h.receivedBytes += int64(n)
			h.mu.Unlock()
		}
		if readErr != nil {
			_ = resp.Body.Close()
			_ = conn.Close()
			h.mu.Lock()
			switch {
			case h.state == "closed":
				// close 已定状态，不动
			case errors.Is(readErr, io.EOF):
				h.state = "eof"
			case isTimeoutError(readErr):
				h.state = "failed"
				h.code, h.stage, h.message = "idle_timeout", "recv", readErr.Error()
			default:
				h.state = "failed"
				h.code, h.stage, h.message = "upstream_reset", "recv", readErr.Error()
			}
			h.respCond.Broadcast()
			h.mu.Unlock()
			return
		}
	}
}

// streamUploadBody 从 h.upload 队列取数据写进 conn。
// **队列空且调用方还没 finish ⇒ 等**（这就是背压的另一半）；`write` 返回 accepted 让调用方重试。
func streamUploadBody(ctx context.Context, h *peerRequestHandle, conn net.Conn, req peerRequestOpenRequest) error {
	chunked := req.BodyLength <= 0
	var total int64
	for {
		h.mu.Lock()
		for h.upload.Len() == 0 && !h.finished && h.state != "closed" {
			h.uploadCond.Wait()
		}
		if h.state == "closed" {
			h.mu.Unlock()
			return context.Canceled
		}
		pending := h.upload.Len()
		var data []byte
		if pending > 0 {
			data = make([]byte, pending)
			_, _ = io.ReadFull(&h.upload, data)
		}
		done := h.finished && h.upload.Len() == 0
		h.mu.Unlock()

		if len(data) > 0 {
			_ = conn.SetWriteDeadline(writeDeadline(req, time.Duration(req.IdleTimeoutMs)*time.Millisecond))
			if chunked {
				if _, err := fmt.Fprintf(conn, "%x\r\n", len(data)); err != nil {
					return err
				}
				if _, err := conn.Write(data); err != nil {
					return err
				}
				if _, err := conn.Write([]byte("\r\n")); err != nil {
					return err
				}
			} else if _, err := conn.Write(data); err != nil {
				return err
			}
			total += int64(len(data))
			h.mu.Lock()
			h.sentBytes = total
			h.mu.Unlock()
		}
		if done {
			if chunked {
				if _, err := conn.Write([]byte("0\r\n\r\n")); err != nil {
					return err
				}
			} else if total != req.BodyLength {
				return fmt.Errorf("body length mismatch: declared %d, sent %d", req.BodyLength, total)
			}
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
}

// writeRequestHead 手写请求行 + 头（**不用 http.Request.Write**，为了完全掌控 Host 与分块）。
func writeRequestHead(conn net.Conn, req peerRequestOpenRequest, port int) error {
	var sb strings.Builder
	sb.WriteString(req.Method)
	sb.WriteString(" ")
	sb.WriteString(req.Path)
	sb.WriteString(" HTTP/1.1\r\n")
	sb.WriteString("Host: ")
	sb.WriteString(requestHost(req, port))
	sb.WriteString("\r\n")
	if req.HasBody {
		if req.BodyLength > 0 {
			sb.WriteString("Content-Length: ")
			sb.WriteString(strconv.FormatInt(req.BodyLength, 10))
			sb.WriteString("\r\n")
		} else {
			sb.WriteString("Transfer-Encoding: chunked\r\n")
		}
	}
	// 调用方给的头：跳过由我们掌控的那几个，键名小写化（契约 §7 的待定小项）
	keys := make([]string, 0, len(req.Headers))
	for k := range req.Headers {
		keys = append(keys, k)
	}
	sortStrings(keys)
	for _, rawKey := range keys {
		key := strings.ToLower(strings.TrimSpace(rawKey))
		switch key {
		case "", "host", "content-length", "transfer-encoding", "connection":
			continue // 由我们定，防误配
		}
		value := strings.TrimSpace(req.Headers[rawKey])
		if strings.ContainsAny(key, "\r\n") || strings.ContainsAny(value, "\r\n") {
			return errors.New("header contains CR/LF")
		}
		sb.WriteString(key)
		sb.WriteString(": ")
		sb.WriteString(value)
		sb.WriteString("\r\n")
	}
	sb.WriteString("\r\n")
	_, err := conn.Write([]byte(sb.String()))
	return err
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}

func flattenHeader(header http.Header) map[string]string {
	out := make(map[string]string, len(header))
	for key, values := range header {
		out[strings.ToLower(key)] = strings.Join(values, ", ")
	}
	return out
}

// readDeadline / writeDeadline：空闲超时为主；若设了整体超时，则取更早的那个。
// `idle <= 0` 时兜到默认值 —— 否则 deadline 会是"此刻"，任何读写立刻 i/o timeout。
func readDeadline(req peerRequestOpenRequest, idle time.Duration) time.Time {
	if idle <= 0 {
		idle = time.Duration(defaultIdleTimeout) * time.Millisecond
	}
	deadline := time.Now().Add(idle)
	if overallMs := req.overallTimeoutMsValue(); overallMs > 0 {
		if overall := time.Now().Add(time.Duration(overallMs) * time.Millisecond); overall.Before(deadline) {
			return overall
		}
	}
	return deadline
}

func writeDeadline(req peerRequestOpenRequest, idle time.Duration) time.Time {
	return readDeadline(req, idle)
}

func isTimeoutError(err error) bool {
	if errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

func (h *peerRequestHandle) currentState() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.state
}

// classifyDialError：把建连失败映射成契约 §7 的码。
func classifyDialError(err error, parent context.Context) string {
	if parent.Err() != nil {
		return "handle_not_found" // 已被 close，父 ctx 取消；状态由 close 定
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "dial_timeout"
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "dial_timeout"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return "dns_failed"
	}
	lower := strings.ToLower(err.Error())
	switch {
	case strings.Contains(lower, "refused"):
		return "dial_refused"
	case strings.Contains(lower, "no route"), strings.Contains(lower, "unreachable"),
		strings.Contains(lower, "network is down"):
		return "peer_offline"
	case strings.Contains(lower, "i/o timeout"):
		return "dial_timeout"
	}
	return "dial_refused"
}

func classifyWriteError(err error) string {
	if errors.Is(err, context.Canceled) {
		return "handle_not_found"
	}
	if isTimeoutError(err) {
		return "idle_timeout"
	}
	return "upstream_reset"
}
