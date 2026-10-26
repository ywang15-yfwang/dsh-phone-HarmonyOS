import { http } from '@kit.NetworkKit';
import { pluginRequest, TextResult } from '../../services/net/DshNet';
import { pairTarget } from '../../services/PairTarget';
import { TransportTarget } from '../../channel/FileTransport';

export interface PermOption {
  value: string;
  name: string;
  description: string;
}

export interface PermState {
  ok: boolean;
  current: string;
  options: PermOption[];
  detail: string;
}

const EMPTY: PermState = { ok: false, current: '', options: [], detail: '取不到权限列表' };

function parse(body: string): PermState {
  try {
    const root: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
    if (root['ok'] !== true) {
      return { ok: false, current: '', options: [], detail: typeof root['error'] === 'string' ? root['error'] as string : '失败' };
    }
    const options: PermOption[] = [];
    const rawOptions: Object | undefined = root['options'];
    if (Array.isArray(rawOptions)) {
      for (let i = 0; i < rawOptions.length; i++) {
        const one: Record<string, Object> = rawOptions[i] as Record<string, Object>;
        if (typeof one['value'] !== 'string' || typeof one['name'] !== 'string') {
          continue;
        }
        options.push({
          value: one['value'] as string,
          name: one['name'] as string,
          description: typeof one['description'] === 'string' ? one['description'] as string : ''
        });
      }
    }
    return {
      ok: true,
      current: typeof root['current'] === 'string' ? root['current'] as string : '',
      options: options,
      detail: ''
    };
  } catch (error) {
    return EMPTY;
  }
}

/** 读当前会话的权限预设（只读） */
export async function fetchPermission(sessionId: string): Promise<PermState> {
  const base: TransportTarget = pairTarget();
  const res: TextResult = await pluginRequest(base.address, base.port, http.RequestMethod.GET,
    `/pair/permissions?sessionId=${encodeURIComponent(sessionId)}`);
  if (res.statusCode <= 0 || res.statusCode >= 300) {
    return { ok: false, current: '', options: [], detail: res.errorMessage.length > 0 ? res.errorMessage : `HTTP ${res.statusCode}` };
  }
  return parse(res.body);
}

/** 切换当前会话的权限预设 */
export async function setPermission(sessionId: string, value: string): Promise<PermState> {
  const base: TransportTarget = pairTarget();
  const body: string = JSON.stringify({ sessionId: sessionId, value: value });
  const res: TextResult = await pluginRequest(base.address, base.port, http.RequestMethod.POST, '/pair/permissions/set', body);
  if (res.statusCode <= 0 || res.statusCode >= 300) {
    return { ok: false, current: '', options: [], detail: res.errorMessage.length > 0 ? res.errorMessage : `HTTP ${res.statusCode}` };
  }
  return parse(res.body);
}

/** 让电脑打开已登录的 dsh 网页（审批的电脑兜底）；不传地址时用当前配对目标 */
export async function openDesktopPage(host: string = '', port: number = 0): Promise<boolean> {
  try {
    const base: TransportTarget = pairTarget();
    const address: string = host.length > 0 ? host : base.address;
    const targetPort: number = port > 0 ? port : base.port;
    const res: TextResult = await pluginRequest(address, targetPort, http.RequestMethod.POST, '/pair/desktop/open');
    return res.statusCode >= 200 && res.statusCode < 300;
  } catch (error) {
    return false;
  }
}
