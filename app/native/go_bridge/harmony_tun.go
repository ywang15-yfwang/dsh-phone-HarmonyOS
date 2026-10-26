package main

import (
	"errors"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/sys/unix"
)

// harmonyTunDevice 把鸿蒙 vpnExtension.VpnConnection.create 返回的**原始 IP 包描述符**
// 适配成 wireguard-go 的 tun.Device 接口。
// 鸿蒙自己负责建接口与配路由，所以这里**不做** Linux 的 TUN ioctl / netlink 监看。
//
// 语义与 _refs\Tailscale-OHOS\native\go_bridge\harmony_tun.go（flypigJ/Tailscale-OHOS@fd49406f）
// 保持一致；本项目按 N3/N11/N12 去掉了参考实现里的 DNS 计数与 Taildrive 相关字段。
type harmonyTunDevice struct {
	file            *os.File
	mtu             int
	events          chan tun.Event
	closeOnce       sync.Once
	readCount       atomic.Uint64
	writeCount      atomic.Uint64
	readByteCount   atomic.Uint64
	writeByteCount  atomic.Uint64
	readErrorCount  atomic.Uint64
	writeErrorCount atomic.Uint64
	trafficSession  uint64
}

func newHarmonyTunDevice(fd, mtu int) (*harmonyTunDevice, error) {
	if fd < 0 {
		return nil, errors.New("invalid TUN descriptor")
	}
	duplicate, err := unix.Dup(fd)
	if err != nil {
		return nil, err
	}
	// wireguard-go 的 TUN reader 把除它自己特判之外的一切读错误当致命错 —— 尤其
	// 它会在 EAGAIN 上直接关掉设备。鸿蒙给的 VPN 描述符可能是非阻塞返回的，所以
	// 显式在**我们这份 dup** 上清掉 O_NONBLOCK，让 reader 阻塞等下一个包；
	// 顺带避免隧道空闲时忙等。
	if err := unix.SetNonblock(duplicate, false); err != nil {
		_ = unix.Close(duplicate)
		return nil, err
	}
	device := &harmonyTunDevice{
		file:           os.NewFile(uintptr(duplicate), "harmony-vpn-tun"),
		mtu:            mtu,
		events:         make(chan tun.Event, 2),
		trafficSession: uint64(time.Now().UnixMilli()),
	}
	device.events <- tun.EventUp
	return device, nil
}

func (d *harmonyTunDevice) File() *os.File { return d.file }

func (d *harmonyTunDevice) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if len(bufs) == 0 || len(sizes) == 0 || offset < 0 || offset >= len(bufs[0]) {
		return 0, errors.New("invalid TUN read buffer")
	}
	n, err := readTunPacket(d.file, bufs[0][offset:])
	if n > 0 {
		sizes[0] = n
		d.readCount.Add(1)
		d.readByteCount.Add(uint64(n))
		return 1, nil
	}
	if err != nil && !isRetriableTunError(err) {
		d.readErrorCount.Add(1)
	}
	return 0, err
}

func (d *harmonyTunDevice) Write(bufs [][]byte, offset int) (int, error) {
	written := 0
	for _, buf := range bufs {
		if offset < 0 || offset > len(buf) {
			return written, errors.New("invalid TUN write buffer")
		}
		packet := buf[offset:]
		n, err := writeTunPacket(d.file, packet)
		if err != nil {
			if !isRetriableTunError(err) {
				d.writeErrorCount.Add(1)
			}
			return written, err
		}
		if n != len(packet) {
			d.writeErrorCount.Add(1)
			return written, io.ErrShortWrite
		}
		d.writeCount.Add(1)
		d.writeByteCount.Add(uint64(n))
		written++
	}
	return written, nil
}

func readTunPacket(reader io.Reader, packet []byte) (int, error) {
	for {
		n, err := reader.Read(packet)
		if err != nil && isRetriableTunError(err) {
			// 阻塞描述符正常不该出 EAGAIN，但绝不能把一次瞬时中断当成设备级致命读错误
			// 交给 wireguard-go。
			continue
		}
		return n, err
	}
}

// writeTunPacket 在底层描述符只接受**部分写**时仍保住包的边界。
// 短写绝不能上报成"整包写成功"：那会把一个已解密的 TCP 段剩下的部分静默丢掉。
func writeTunPacket(writer io.Writer, packet []byte) (int, error) {
	written := 0
	for written < len(packet) {
		n, err := writer.Write(packet[written:])
		if n > 0 {
			written += n
		}
		if err != nil {
			if isRetriableTunError(err) {
				continue
			}
			return written, err
		}
		if n == 0 {
			return written, io.ErrNoProgress
		}
	}
	return written, nil
}

func (d *harmonyTunDevice) MTU() (int, error) { return d.mtu, nil }

func (d *harmonyTunDevice) Name() (string, error) { return "tailscale0", nil }

func (d *harmonyTunDevice) Events() <-chan tun.Event { return d.events }

func (d *harmonyTunDevice) Close() error {
	var err error
	d.closeOnce.Do(func() {
		d.events <- tun.EventDown
		close(d.events)
		err = d.file.Close()
	})
	return err
}

func (d *harmonyTunDevice) BatchSize() int { return 1 }

func (d *harmonyTunDevice) packetCounts() (read uint64, written uint64) {
	return d.readCount.Load(), d.writeCount.Load()
}

// trafficCounts 报告当前 VPN TUN 生命周期内的字节数。
// 从 TUN 读出来 = 设备上行；把解密后的包写回去 = 设备下行。
func (d *harmonyTunDevice) trafficCounts() (txBytes uint64, rxBytes uint64, session uint64) {
	return d.readByteCount.Load(), d.writeByteCount.Load(), d.trafficSession
}

func (d *harmonyTunDevice) errorCounts() (readErrors uint64, writeErrors uint64) {
	return d.readErrorCount.Load(), d.writeErrorCount.Load()
}

func isRetriableTunError(err error) bool {
	return errors.Is(err, unix.EAGAIN) ||
		errors.Is(err, unix.EWOULDBLOCK) ||
		errors.Is(err, unix.EINTR)
}

var _ tun.Device = (*harmonyTunDevice)(nil)
