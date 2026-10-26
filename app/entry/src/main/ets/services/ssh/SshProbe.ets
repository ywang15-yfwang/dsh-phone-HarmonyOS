import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 「这台机器能不能被 SSH 拉起来」的判据：**它的 SSH 端口真的开着**。
 *
 * 为什么需要判：首页列表里除了电脑，还有手机等其他设备也在 tailnet 里；
 * 它们没有 sshd，之前照样显示了「启动」按钮 —— 点了必然失败（客户 2026-10-21 指出）。
 *
 * 口径：
 *  · 只对**在线且 dsh 没起**的那几行探，一次刷新探一次，**不轮询、不常驻**；
 *  · 超时给得很短（默认 1200ms）：探的是"端口开没开"，不握手、不认证；
 *  · 探不通一律当"不能启动"（宁可少显示一个按钮，也不给一个点了必然失败的按钮）。
 */
export function tcpOpen(host: string, port: number, timeoutMs: number = 1200): Promise<boolean> {
  return new Promise<boolean>((resolve: (v: boolean) => void) => {
    let settled: boolean = false;
    let timer: number = -1;
    let sock: socket.TCPSocket | undefined = undefined;

    const finish = (ok: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer >= 0) {
        clearTimeout(timer);
        timer = -1;
      }
      resolve(ok);
      const s: socket.TCPSocket | undefined = sock;
      if (s !== undefined) {
        try {
          s.close();
        } catch (error) {
          // 已关闭
        }
      }
    };

    timer = setTimeout(() => {
      finish(false);
    }, timeoutMs);

    const s: socket.TCPSocket = socket.constructTCPSocketInstance();
    sock = s;
    s.on('error', (err: BusinessError) => {
      finish(false);
    });
    const addr: socket.NetAddress = { address: host, port: port };
    s.connect({ address: addr, timeout: timeoutMs }).then(() => {
      finish(true);
    }).catch((_e: BusinessError) => {
      finish(false);
    });
  });
}

