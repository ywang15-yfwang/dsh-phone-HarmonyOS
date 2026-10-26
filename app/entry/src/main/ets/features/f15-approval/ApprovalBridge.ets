import { RawWs, RawWsTarget } from '../../services/RawWs';
import { pairTarget } from '../../services/PairTarget';
import { TransportTarget } from '../../channel/FileTransport';

export interface ApprovalRequest {
  id: string;
  sessionId: string;
  toolName: string;
  callId: string;
  reason: string;
  displayReason: string;
}

/**
 * 手机侧审批通道（只读状态 + 遥控网页按钮）：
 *  - 进会话页连插件；连上即打招呼，插件把未决审批推过来；
 *  - 回前台可 refresh()（发 approval/list）补拉；
 *  - 决定发给插件；插件去点网页按钮，电脑先点会推 approval/cancelled。
 */
export class ApprovalBridge {
  private ws: RawWs | undefined = undefined;
  private stopped: boolean = false;
  private retryTimer: number = -1;
  private retryCount: number = 0;

  onRequest: (request: ApprovalRequest) => void = () => { };
  onPendingList: (items: ApprovalRequest[]) => void = () => { };
  onCancelled: (id: string) => void = () => { };
  onClickFailed: (id: string, reason: string) => void = () => { };
  onClosed: () => void = () => { };

  connect(): void {
    if (this.ws !== undefined || this.stopped) {
      return;
    }
    const base: TransportTarget = pairTarget();
    const hostHeader: string = base.hostHeader ?? `127.0.0.1:${base.port}`;
    const target: RawWsTarget = {
      host: base.address,
      port: base.port,
      path: '/pair/approvals',
      hostHeader: hostHeader,
      origin: `http://${hostHeader}`,
      cookie: base.cookie ?? ''
    };
    const ws: RawWs = new RawWs();
    this.ws = ws;
    ws.onOpen = () => {
      this.retryCount = 0;
      try {
        ws.sendText(JSON.stringify({ type: 'hello', role: 'phone' }));
      } catch (error) {
        // 忽略
      }
    };
    ws.onText = (text: string) => {
      this.handle(text);
    };
    ws.onClose = (code: number, reason: string) => {
      this.ws = undefined;
      this.scheduleRetry();
      this.onClosed();
    };
    ws.onFail = (message: string) => {
      this.ws = undefined;
      this.scheduleRetry();
      this.onClosed();
    };
    ws.connect(target);
  }

  /** 回前台补拉一次 */
  refresh(): void {
    const ws: RawWs | undefined = this.ws;
    if (ws === undefined) {
      this.connect();
      return;
    }
    try {
      ws.sendText(JSON.stringify({ type: 'approval/list' }));
    } catch (error) {
      // 忽略
    }
  }

  decide(id: string, allow: boolean): void {
    const ws: RawWs | undefined = this.ws;
    if (ws === undefined) {
      return;
    }
    ws.sendText(JSON.stringify({ type: 'approval/decide', id: id, outcome: allow ? 'allowed-once' : 'rejected' }));
  }

  close(): void {
    this.stopped = true;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const ws: RawWs | undefined = this.ws;
    this.ws = undefined;
    if (ws !== undefined) {
      ws.close();
    }
  }

  private scheduleRetry(): void {
    if (this.stopped || this.retryTimer >= 0 || this.retryCount >= 5) {
      return;
    }
    this.retryCount += 1;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.connect();
    }, 2000);
  }

  private parseItem(raw: Object): ApprovalRequest | undefined {
    try {
      const one: Record<string, Object> = raw as Record<string, Object>;
      if (typeof one['id'] !== 'string') {
        return undefined;
      }
      return {
        id: one['id'] as string,
        sessionId: typeof one['sessionId'] === 'string' ? one['sessionId'] as string : '',
        toolName: typeof one['toolName'] === 'string' ? one['toolName'] as string : '',
        callId: typeof one['callId'] === 'string' ? one['callId'] as string : '',
        reason: typeof one['reason'] === 'string' ? one['reason'] as string : '',
        displayReason: typeof one['displayReason'] === 'string' ? one['displayReason'] as string : ''
      };
    } catch (error) {
      return undefined;
    }
  }

  private handle(text: string): void {
    try {
      const msg: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const type: string = typeof msg['type'] === 'string' ? msg['type'] as string : '';
      if (type === 'approval/pending-list') {
        const raw: Object | undefined = msg['items'];
        const items: ApprovalRequest[] = [];
        if (Array.isArray(raw)) {
          for (let i = 0; i < raw.length; i++) {
            const one: ApprovalRequest | undefined = this.parseItem(raw[i] as Object);
            if (one !== undefined) {
              items.push(one);
            }
          }
        }
        this.onPendingList(items);
        return;
      }
      if (type === 'approval/pending') {
        const one: ApprovalRequest | undefined = this.parseItem(msg['item'] as Object);
        if (one !== undefined) {
          this.onRequest(one);
        }
        return;
      }
      if (type === 'approval/cancelled') {
        this.onCancelled(typeof msg['id'] === 'string' ? msg['id'] as string : '');
        return;
      }
      if (type === 'approval/click-failed') {
        this.onClickFailed(typeof msg['id'] === 'string' ? msg['id'] as string : '',
          typeof msg['reason'] === 'string' ? msg['reason'] as string : '');
      }
    } catch (error) {
      // 忽略坏消息
    }
  }
}
