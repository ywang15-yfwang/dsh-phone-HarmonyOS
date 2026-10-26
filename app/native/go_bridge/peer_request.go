package main

// peer_request.go —— A 路「经内核 netstack 到 tailnet」的**带句柄流式请求**。
//
// 契约：harmonyos-app-toolchain\docs\p2-kernel-request-export-contract-draft.md
//      （签名/语义的**单一来源**是那份契约 + index.d.ts；本文件改动必须同步那两处）
//
// 为什么必须有这一层（一句话）：我方用 `blockedApplications: [自己]` 把整个 bundle 排除在 VPN 之外
// ⇒ **App 的普通 socket 到 100.x 会绕过 VPN 并超时**（该 fork 的 patch 注释原话，tailscale-ohos.patch:404-410）
// ⇒ 到 tailnet 的流量只能由**内核**经 netstack 发。**手机侧零监听**（B 路方案已否，别在这里偷加监听）。
//
// 走 netstack 的依据：tsnet.go:731-734 —— `externalTun && UseNetstackForPeerDial`
// ⇒ `dialer.UseNetstackForIP = tsaddr.IsTailscaleIP`，"所有 canonical tailnet 目的地必须走内嵌 netstack"。
// 我们 backend.go 里 `UseNetstackForPeerDial: device != nil` 正是这个模式 ⇒ `server.Dial(...)` 即走 netstack。
//
// 三条设计纪律（照契约，不要"优化"掉）：
//  1. **5 个函数全部非阻塞** —— NAPI 是拉模型：`read` 只取"已到达的"，没数据也立即返回；**不提供 Async 变体**。
//  2. **背压 = 部分写** —— `write` 返回本次真正收下的字节数（`accepted`），调用方**必须重试剩余部分**；
//     上传队列 8 MiB、接收缓冲高水位 2 MiB ⇒ 不丢数据、不内存爆。
//  3. **目标两重白名单，fail-closed** —— `target` 必须命中当前 `Status.Peer` 的地址；`port` 必须在
//     `allowedPorts` 里（**空 ⇒ 全拒**）。这不是"通用代理"。
//
// 第四条（F14 · 客户端纪律，2026-10-13 补）：**句柄不挂在后端生命周期上**（重连/重订阅归 App，契约 §8 取舍二）
// ⇒ **后端 stop / 换 tun 重建时必须由 `drainPeerRequestHandles` 主动清干净**，
// 否则"断开之后手机侧还有内核网络动作在跑"（见该函数注释）。

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"net/url"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/client/local"
)

const (
	// 并发句柄上限（契约 §6）
	maxPeerRequestHandles = 8
	// 上传队列上限：write 收满就不再多收，调用方重试（契约 §5）
	uploadQueueCap = 8 << 20
	// 接收缓冲高水位：到这儿就停止从 socket 读，等 App 取走（背压，契约 §3）
	responseHighWater = 2 << 20
	// read 单次返回上限的硬顶（调用方 maxBytes 再大也不超过它）
	maxReadBytes = 4 << 20
	// 默认值（契约 §2）
	defaultConnTimeout    = 5000
	defaultHeaderTimeout  = 10000
	defaultOverallTimeout = 30000
	defaultIdleTimeout    = 120000
	defaultMaxChunkBytes  = 1 << 20
)

// ---------------------------------------------------------------- DTO

type peerRequestOpenRequest struct {
	Target           string            `json:"target"`
	Port             int               `json:"port"`
	AllowedPorts     []int             `json:"allowedPorts"`
	Method           string            `json:"method"`
	Path             string            `json:"path"`
	Host             string            `json:"host"`
	Headers          map[string]string `json:"headers"`
	HasBody          bool              `json:"hasBody"`
	BodyLength       int64             `json:"bodyLength"`
	ConnectTimeoutMs int               `json:"connectTimeoutMs"`
	ResponseHeaderMs int               `json:"responseHeaderTimeoutMs"`
	// **必须是指针**：`0` 表示"显式不设整体超时"（事件流要这个），
	// 而**没传**这个字段应当取默认 30s —— 用 int 两者分不开，
	// 会静默地把普通请求变成"永不过期"（危险）。写个单测钉住它。
	OverallTimeoutMs *int `json:"overallTimeoutMs"`
	IdleTimeoutMs    int  `json:"idleTimeoutMs"`
	MaxChunkBytes    int  `json:"maxChunkBytes"`
}

// overallTimeoutMsValue：没传 ⇒ 默认；显式 0 ⇒ 不设整体超时。
func (r peerRequestOpenRequest) overallTimeoutMsValue() int {
	if r.OverallTimeoutMs == nil {
		return defaultOverallTimeout
	}
	return *r.OverallTimeoutMs
}

type peerRequestOpenResult struct {
	OK        bool   `json:"ok"`
	Handle    uint64 `json:"handle,omitempty"`
	State     string `json:"state,omitempty"`
	Authority string `json:"authority,omitempty"`
	Target    string `json:"target,omitempty"`
	Code      string `json:"code,omitempty"`
	Stage     string `json:"stage,omitempty"`
	Message   string `json:"message,omitempty"`
}

type peerRequestWriteResult struct {
	OK        bool   `json:"ok"`
	State     string `json:"state,omitempty"`
	Accepted  int    `json:"accepted"`
	SentBytes int64  `json:"sentBytes"`
	Queued    int    `json:"queuedBytes"`
	Code      string `json:"code,omitempty"`
	Stage     string `json:"stage,omitempty"`
	Message   string `json:"message,omitempty"`
}

type peerRequestReadResult struct {
	OK            bool              `json:"ok"`
	State         string            `json:"state,omitempty"`
	Status        int               `json:"status,omitempty"`
	Headers       map[string]string `json:"headers,omitempty"`
	DataBase64    string            `json:"dataBase64"`
	Bytes         int               `json:"bytes"`
	ReceivedBytes int64             `json:"receivedBytes"`
	SentBytes     int64             `json:"sentBytes"`
	EOF           bool              `json:"eof"`
	ElapsedMs     int64             `json:"elapsedMs,omitempty"`
	Code          string            `json:"code,omitempty"`
	Stage         string            `json:"stage,omitempty"`
	Message       string            `json:"message,omitempty"`
}

type peerRequestCloseResult struct {
	OK        bool   `json:"ok"`
	Cancelled bool   `json:"cancelled,omitempty"`
	State     string `json:"state,omitempty"`
	Code      string `json:"code,omitempty"`
	Stage     string `json:"stage,omitempty"`
	Message   string `json:"message,omitempty"`
}

// ---------------------------------------------------------------- 句柄

type peerRequestHandle struct {
	id        uint64
	startedAt time.Time

	mu            sync.Mutex
	state         string // dialing|sending|awaiting-response|streaming|eof|failed|closed
	code          string
	stage         string
	message       string
	status        int
	headers       map[string]string
	respBuf       bytes.Buffer
	upload        bytes.Buffer
	sentBytes     int64
	receivedBytes int64
	finished      bool
	respCond      *sync.Cond // 读侧背压：缓冲被取走时唤醒 reader
	uploadCond    *sync.Cond // 写侧：有新数据时唤醒 writer

	cancel context.CancelFunc
	conn   net.Conn
	body   io.ReadCloser
}

var (
	peerRequestMu     sync.Mutex
	peerRequestTable  = map[uint64]*peerRequestHandle{}
	peerRequestNextID atomic.Uint64
)

func (h *peerRequestHandle) setState(state, code, stage, message string) {
	h.mu.Lock()
	h.state = state
	if code != "" {
		h.code, h.stage, h.message = code, stage, message
	}
	h.mu.Unlock()
}

func (h *peerRequestHandle) fail(code, stage string, err error) {
	h.mu.Lock()
	if h.state != "closed" {
		h.state = "failed"
		h.code, h.stage = code, stage
		if err != nil {
			h.message = err.Error()
		}
	}
	h.mu.Unlock()
}

// ---------------------------------------------------------------- 对外：5 个动作

func (b *backendController) peerRequestOpen(requestJSON string) string {
	req, errResult := parsePeerRequest(requestJSON)
	if errResult != nil {
		return marshalJSON(errResult)
	}

	// ---- 前置：内核必须在跑，且必须有 tun（否则不是"入网"，报 no_tun —— 契约 §7）
	b.mu.Lock()
	server := b.server
	client := b.client
	hasTun := b.tunDevice != nil
	b.mu.Unlock()
	if server == nil || client == nil {
		return marshalJSON(peerRequestOpenResult{
			OK: false, Code: "kernel_not_running", Stage: "precheck",
			Message: "backend is not running"})
	}
	if !hasTun {
		return marshalJSON(peerRequestOpenResult{
			OK: false, Code: "no_tun", Stage: "precheck",
			Message: "backend is running without an external TUN"})
	}

	// ---- 目标两重白名单（fail-closed）
	dialAddr, port, res := resolvePeerTarget(client, req)
	if res != nil {
		return marshalJSON(*res)
	}

	// ---- 起句柄
	if countPeerRequestHandles() >= maxPeerRequestHandles {
		return marshalJSON(peerRequestOpenResult{
			OK: false, Code: "too_many_handles", Stage: "precheck",
			Message: fmt.Sprintf("concurrent handle limit is %d", maxPeerRequestHandles)})
	}

	parent := context.Background()
	var cancel context.CancelFunc
	if overallMs := req.overallTimeoutMsValue(); overallMs > 0 {
		parent, cancel = context.WithTimeout(parent, time.Duration(overallMs)*time.Millisecond)
	} else {
		// 显式 0 = 不设整体超时（事件流必须这样）
		parent, cancel = context.WithCancel(parent)
	}

	h := &peerRequestHandle{
		id:        peerRequestNextID.Add(1),
		startedAt: time.Now(),
		state:     "dialing",
		headers:   map[string]string{},
		cancel:    cancel,
	}
	h.respCond = sync.NewCond(&h.mu)
	h.uploadCond = sync.NewCond(&h.mu)
	registerPeerRequestHandle(h)

	go b.runPeerRequest(parent, h, server, req, dialAddr, port)

	return marshalJSON(peerRequestOpenResult{
		OK: true, Handle: h.id, State: "dialing",
		Authority: requestHost(req, port), Target: net.JoinHostPort(dialAddr, fmt.Sprint(port))})
}

func (b *backendController) peerRequestWrite(handleID uint64, chunkB64 string) string {
	h := lookupPeerRequestHandle(handleID)
	if h == nil {
		return marshalJSON(peerRequestWriteResult{OK: false, Code: "handle_not_found", Message: "unknown handle"})
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.state == "closed" {
		return marshalJSON(peerRequestWriteResult{OK: false, State: h.state,
			Code: "handle_not_found", Message: "handle already closed"})
	}
	if h.finished {
		return marshalJSON(peerRequestWriteResult{OK: false, State: h.state,
			Code: "write_after_finish", Message: "request body already finished"})
	}
	chunk, err := base64.StdEncoding.DecodeString(chunkB64)
	if err != nil {
		return marshalJSON(peerRequestWriteResult{OK: false, State: h.state,
			Code: "invalid_request", Message: "chunk is not valid base64"})
	}
	// **部分写语义**：只收下队列还能装的那部分，其余由调用方重试。
	room := uploadQueueCap - h.upload.Len()
	accepted := len(chunk)
	if accepted > room {
		accepted = room
	}
	if accepted > 0 {
		h.upload.Write(chunk[:accepted])
		h.uploadCond.Broadcast()
	}
	return marshalJSON(peerRequestWriteResult{
		OK: true, State: h.state, Accepted: accepted, SentBytes: h.sentBytes, Queued: h.upload.Len()})
}

func (b *backendController) peerRequestFinish(handleID uint64) string {
	h := lookupPeerRequestHandle(handleID)
	if h == nil {
		return marshalJSON(peerRequestWriteResult{OK: false, Code: "handle_not_found", Message: "unknown handle"})
	}
	h.mu.Lock()
	h.finished = true
	state := h.state
	h.uploadCond.Broadcast()
	h.mu.Unlock()
	return marshalJSON(peerRequestWriteResult{OK: true, State: state, SentBytes: h.sentBytes})
}

func (b *backendController) peerRequestRead(handleID uint64, maxBytes int) string {
	h := lookupPeerRequestHandle(handleID)
	if h == nil {
		return marshalJSON(peerRequestReadResult{OK: false, Code: "handle_not_found", Message: "unknown handle"})
	}
	if maxBytes <= 0 {
		maxBytes = defaultMaxChunkBytes
	}
	if maxBytes > maxReadBytes {
		maxBytes = maxReadBytes
	}

	h.mu.Lock()
	out := peerRequestReadResult{
		OK: true, State: h.state, Status: h.status,
		ReceivedBytes: h.receivedBytes, SentBytes: h.sentBytes,
		EOF:       h.state == "eof",
		ElapsedMs: time.Since(h.startedAt).Milliseconds(),
	}
	if out.State == "failed" {
		out.OK = false
		out.Code, out.Stage, out.Message = h.code, h.stage, h.message
	}
	if len(h.headers) > 0 {
		out.Headers = make(map[string]string, len(h.headers))
		for k, v := range h.headers {
			out.Headers[k] = v
		}
	}
	if n := h.respBuf.Len(); n > 0 {
		if n > maxBytes {
			n = maxBytes
		}
		chunk := make([]byte, n)
		_, _ = io.ReadFull(&h.respBuf, chunk)
		out.DataBase64 = base64.StdEncoding.EncodeToString(chunk)
		out.Bytes = n
		h.respCond.Broadcast() // 释放背压：让 reader 继续从 socket 读
	}
	h.mu.Unlock()
	return marshalJSON(out)
}

func (b *backendController) peerRequestClose(handleID uint64) string {
	h := unregisterPeerRequestHandle(handleID)
	if h == nil {
		return marshalJSON(peerRequestCloseResult{OK: false, Code: "handle_not_found", Message: "unknown handle"})
	}
	cancelled := teardownPeerRequestHandle(h, "", "", "")
	return marshalJSON(peerRequestCloseResult{OK: true, Cancelled: cancelled, State: "closed"})
}

// teardownPeerRequestHandle 是 close 的全部副作用；「单句柄 close」与「停后端清理」共用这一份实现，
// 免得两处各写一遍、日后只改一处。
// 调用约定：调用方必须已经把它从句柄表里摘掉（或不再需要按 id 找到它）。
// 返回 true = 这一次真的取消了（此前不是 closed）。
func teardownPeerRequestHandle(h *peerRequestHandle, code, stage, message string) bool {
	h.mu.Lock()
	alreadyClosed := h.state == "closed"
	h.state = "closed"
	if code != "" {
		h.code, h.stage, h.message = code, stage, message
	}
	h.uploadCond.Broadcast()
	h.respCond.Broadcast()
	conn, body, cancel := h.conn, h.body, h.cancel
	h.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if body != nil {
		_ = body.Close()
	}
	if conn != nil {
		_ = conn.Close()
	}
	return !alreadyClosed
}

// drainPeerRequestHandles 是 F14「随时可退出、断开后手机侧不残留」的落地：
// 后端 stop / 换 tun 重建时，把**所有在途句柄**一并取消、断连、清空句柄表。
//
// 为什么必须在这里做（不能指望 close）：
//   - open 的 context 派生自 context.Background()，**刻意不挂在后端生命周期上**（契约 §8 取舍二：
//     重连/重订阅归 App），所以停后端**不会**自动取消它们。不清理就会留下
//     "断开之后仍在跑的内核网络动作"，并且 8 个句柄槽会被上一代占满（再 open 就 too_many_handles）。
//   - 阶段是 go 里唯一持有 conn / cancel 的地方，只有这里能真正断连。
//
// 语义（与契约 §7 `handle_not_found` = "句柄已关 / 不存在" 一致）：被摘表之后按 id 查是
// `handle_not_found`；而**在此之前已经拿到该指针**的并发调用会读到
// `state=closed` + `code=kernel_not_running`（先定终态、再摘表，两者都不含糊）。
func drainPeerRequestHandles(code, stage, message string) int {
	peerRequestMu.Lock()
	handles := make([]*peerRequestHandle, 0, len(peerRequestTable))
	for _, h := range peerRequestTable {
		handles = append(handles, h)
	}
	peerRequestTable = make(map[uint64]*peerRequestHandle)
	peerRequestMu.Unlock()

	for _, h := range handles {
		teardownPeerRequestHandle(h, code, stage, message)
	}
	return len(handles)
}

// ---------------------------------------------------------------- 句柄表

func registerPeerRequestHandle(h *peerRequestHandle) {
	peerRequestMu.Lock()
	peerRequestTable[h.id] = h
	peerRequestMu.Unlock()
}

func lookupPeerRequestHandle(id uint64) *peerRequestHandle {
	peerRequestMu.Lock()
	defer peerRequestMu.Unlock()
	return peerRequestTable[id]
}

func unregisterPeerRequestHandle(id uint64) *peerRequestHandle {
	peerRequestMu.Lock()
	defer peerRequestMu.Unlock()
	h := peerRequestTable[id]
	delete(peerRequestTable, id)
	return h
}

func countPeerRequestHandles() int {
	peerRequestMu.Lock()
	defer peerRequestMu.Unlock()
	return len(peerRequestTable)
}

// ---------------------------------------------------------------- 白名单与解析

type hostLookup func(ctx context.Context, host string) ([]string, error)

func defaultHostLookup(ctx context.Context, host string) ([]string, error) {
	return net.DefaultResolver.LookupHost(ctx, host)
}

func denyTarget(message string) *peerRequestOpenResult {
	return &peerRequestOpenResult{OK: false, Code: "target_not_allowed", Stage: "precheck", Message: message}
}

// checkTargetWhitelist 是**两重白名单**的纯函数形态（fail-closed）：
//  1. `port` 必须在 `allowedPorts` 里；**列表为空 ⇒ 全拒**；
//  2. `target` 必须命中 `allowed`（当前 Status.Peer 的地址集合）——
//     IP 直接查；`*.ts.net` 名**解析后**再查（解析器可注入 ⇒ 可单测）。
//
// 返回可拨号的 IP；不允许时返回非 nil 的 deny 结果。
func checkTargetWhitelist(
	req peerRequestOpenRequest, allowed map[string]bool, lookup hostLookup,
) (string, *peerRequestOpenResult) {
	if len(req.AllowedPorts) == 0 {
		return "", denyTarget("allowedPorts is empty (fail-closed)")
	}
	portAllowed := false
	for _, p := range req.AllowedPorts {
		if p == req.Port {
			portAllowed = true
			break
		}
	}
	if !portAllowed {
		return "", denyTarget(fmt.Sprintf("port %d is not in allowedPorts", req.Port))
	}
	if len(allowed) == 0 {
		return "", &peerRequestOpenResult{OK: false, Code: "peer_offline", Stage: "precheck",
			Message: "no discovered tailnet peers"}
	}

	target := strings.TrimSpace(req.Target)
	if ip, err := netip.ParseAddr(target); err == nil {
		if allowed[ip.String()] {
			return ip.String(), nil
		}
		return "", denyTarget("target is not a currently discovered peer address")
	}
	if target == "" || strings.Contains(target, "/") || strings.Contains(target, ":") {
		return "", denyTarget("target must be a tailnet IP or a *.ts.net name")
	}
	host := strings.TrimSuffix(strings.ToLower(target), ".")
	if host == "" || !strings.Contains(host, ".") {
		return "", denyTarget("target must be a tailnet IP or a *.ts.net name")
	}
	if !strings.HasSuffix(host, ".ts.net") {
		return "", denyTarget("only *.ts.net names are accepted")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	ips, err := lookup(ctx, host)
	if err != nil {
		return "", &peerRequestOpenResult{OK: false, Code: "dns_failed", Stage: "dns", Message: err.Error()}
	}
	sorted := append([]string(nil), ips...)
	sort.Strings(sorted) // 结果确定：同样的输入给同样的目标
	for _, raw := range sorted {
		if allowed[raw] {
			return raw, nil
		}
	}
	return "", denyTarget("resolved address is not a currently discovered peer address")
}

// resolvePeerTarget 把当前内核的 peer 地址集合喂给上面的纯函数。
func resolvePeerTarget(client *local.Client, req peerRequestOpenRequest) (string, int, *peerRequestOpenResult) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return "", 0, &peerRequestOpenResult{OK: false, Code: "kernel_not_running", Stage: "precheck",
			Message: "peer list unavailable: " + err.Error()}
	}
	allowed := map[string]bool{}
	for _, peer := range status.Peer {
		if peer == nil {
			continue
		}
		for _, addr := range peer.TailscaleIPs {
			allowed[addr.String()] = true
		}
	}
	ip, denied := checkTargetWhitelist(req, allowed, defaultHostLookup)
	if denied != nil {
		return "", 0, denied
	}
	return ip, req.Port, nil
}

func parsePeerRequest(requestJSON string) (peerRequestOpenRequest, *peerRequestOpenResult) {
	req := peerRequestOpenRequest{}
	deny := func(message string) (peerRequestOpenRequest, *peerRequestOpenResult) {
		return req, &peerRequestOpenResult{OK: false, Code: "invalid_request", Stage: "precheck", Message: message}
	}
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil {
		return deny("request is not valid JSON: " + err.Error())
	}
	if strings.TrimSpace(req.Target) == "" {
		return deny("target is required")
	}
	if req.Port < 1 || req.Port > 65535 {
		return deny("port must be within 1..65535")
	}
	if req.Path == "" || !strings.HasPrefix(req.Path, "/") {
		return deny("path is required and must start with /")
	}
	if _, err := url.ParseRequestURI(req.Path); err != nil {
		return deny("path is not a valid request URI: " + err.Error())
	}
	if req.Method == "" {
		req.Method = "GET"
	}
	req.Method = strings.ToUpper(req.Method)
	if !validHTTPMethod(req.Method) {
		return deny("method is not a valid token")
	}
	if req.ConnectTimeoutMs <= 0 {
		req.ConnectTimeoutMs = defaultConnTimeout
	}
	if req.ResponseHeaderMs <= 0 {
		req.ResponseHeaderMs = defaultHeaderTimeout
	}
	// 没传 ⇒ 默认（accessor 处理）；显式 0 ⇒ 不设整体超时（事件流）；负数 ⇒ 非法。
	if req.OverallTimeoutMs != nil && *req.OverallTimeoutMs < 0 {
		return deny("overallTimeoutMs must be >= 0 (0 means no overall timeout)")
	}
	if req.IdleTimeoutMs <= 0 {
		req.IdleTimeoutMs = defaultIdleTimeout
	}
	if req.MaxChunkBytes <= 0 || req.MaxChunkBytes > maxReadBytes {
		req.MaxChunkBytes = defaultMaxChunkBytes
	}
	return req, nil
}

func validHTTPMethod(m string) bool {
	if m == "" {
		return false
	}
	for _, r := range m {
		switch {
		case r >= 'A' && r <= 'Z':
		case r >= 'a' && r <= 'z':
		case r == '-':
		default:
			return false
		}
	}
	return true
}

// requestHost 是**契约 §4 的要害**：Host 由我们定，默认回环形式。
// 依据：T2N 实测 dsh 的 /api 围栏判据是 Host，非回环一律 403。
func requestHost(req peerRequestOpenRequest, port int) string {
	if h := strings.TrimSpace(req.Host); h != "" {
		return h
	}
	return fmt.Sprintf("127.0.0.1:%d", port)
}
