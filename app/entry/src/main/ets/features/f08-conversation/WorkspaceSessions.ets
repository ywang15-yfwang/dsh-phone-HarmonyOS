import { hilog } from '@kit.PerformanceAnalysisKit';
import { DSH_PATH_PREFIX } from '../../model/EntryPorts';
import { activeProfile } from '../../services/ProfileStore';
import { RawWs, RawWsTarget } from '../../services/RawWs';
import { SessionRow } from './DshSessionPage';

/**
 * **官方分组视图**（客户 2026-10-17：列表只给「DeepSeek 下面」的会话，不要全量推过来再筛）。
 *
 * 依据（dsh 源码 `dsh-api-workspace-controller/lib/typert.host.js`）：
 * `workspace/follow` 是 stream 方法，首帧即
 * `{type:'item', value:{type:'baseline', value:{items:[{workspaceId,path,title,sessionIds[]}],
 *   archivedSessionIds:[], pinnedSessionIds:[]}}}`。
 *
 * 手机现在**直连**这条流（`services/RawWs.ets` 自建握手，不需要任何转发）：
 * 取到首帧就够画列表，取完立刻断开（列表不需要实时）。
 *
 * 显示规则照抄官方侧栏（`dsh-client-ui-workspace/lib/client.js` 的 `sessionVisible`）：
 *   · 只要**这个工作区**（path 与当前会话的 cwd 相同）的会话；
 *   · 子 agent 会话（`origin === 'subagent'`）不显示；
 *   · 归档的不显示（`archivedSessionIds`）；
 *   · 空会话只显示当前这一场；
 *   · 顺序：置顶优先，其余按最近活动倒序。
 */

const DOMAIN: number = 0xD001;
const TAG: string = 'F5GROUP';

export interface WorkspaceView {
  workspaceId: string;
  path: string;
  title: string;
  sessionIds: string[];
}

export interface WorkspaceState {
  ok: boolean;
  items: WorkspaceView[];
  archived: string[];
  pinned: string[];
  detail: string;
}

function emptyState(detail: string): WorkspaceState {
  return { ok: false, items: [], archived: [], pinned: [], detail: detail };
}

/** 空的分组视图（取不到时用它：只保留"尽力剔除"的过滤） */
export function emptyWorkspaceState(): WorkspaceState {
  return emptyState('未取到分组视图');
}

/**
 * 取一次官方分组视图（一次 WS、首帧即返回、随后断开）。
 * `cookieHead` = 配对拿到的 `name=value`；`pluginHost` = 插件地址（真机 tailnet `100.x`）。
 * dsh 只听回环 ⇒ 走插件 `插件端口` + `/pair/dsh` 前缀，Host 仍写回环 `127.0.0.1:dsh 端口`。
 */
export async function fetchWorkspaceState(pluginHost: string, cookieHead: string): Promise<WorkspaceState> {
  if (cookieHead.length === 0) {
    return emptyState('没有凭据');
  }
  const target: RawWsTarget = {
    host: pluginHost,
    port: activeProfile().pluginPort,
    path: `${DSH_PATH_PREFIX}/api/remote.mux`,
    hostHeader: `127.0.0.1:${activeProfile().dshPort}`,
    origin: `http://127.0.0.1:${activeProfile().dshPort}`,
    cookie: cookieHead
  };
  const ws: RawWs = new RawWs();
  const state: WorkspaceState = await new Promise<WorkspaceState>((resolve: (v: WorkspaceState) => void) => {
    let settled: boolean = false;
    const done = (value: WorkspaceState): void => {
      if (settled) {
        return;
      }
      settled = true;
      ws.close();
      resolve(value);
    };
    const timer: number = setTimeout(() => {
      done(emptyState('取分组视图超时'));
    }, 6000);
    ws.onOpen = () => {
      ws.sendText('{"type":"open","streamId":"ws1","endpoint":"workspace/follow","payload":{"args":{}}}');
    };
    ws.onText = (text: string) => {
      const parsed: WorkspaceState | undefined = parseBaseline(text);
      if (parsed !== undefined) {
        clearTimeout(timer);
        done(parsed);
      }
    };
    ws.onFail = (message: string) => {
      clearTimeout(timer);
      hilog.warn(DOMAIN, TAG, '分组视图失败：%{public}s', message);
      done(emptyState(message));
    };
    ws.onClose = () => {
      clearTimeout(timer);
      if (!settled) {
        done(emptyState('连接被关闭'));
      }
    };
    ws.connect(target);
  });
  hilog.info(DOMAIN, TAG, '分组视图：ok=%{public}s 工作区=%{public}d 归档=%{public}d 置顶=%{public}d（%{public}s）',
    `${state.ok}`, state.items.length, state.archived.length, state.pinned.length, state.detail);
  return state;
}

/** 解析 `workspace/follow` 的首帧（不是 baseline 就返回 undefined） */
function parseBaseline(text: string): WorkspaceState | undefined {
  if (text.indexOf('"baseline"') < 0) {
    return undefined;
  }
  try {
    const msg = JSON.parse(text) as Record<string, Object>;
    const value = msg['value'] as Record<string, Object>;
    const base = value['value'] as Record<string, Object>;
    const rawItems = base['items'] as Object[];
    const items: WorkspaceView[] = [];
    for (let i = 0; i < rawItems.length; i++) {
      const one = rawItems[i] as Record<string, Object>;
      const idsRaw = one['sessionIds'] as Object[];
      const ids: string[] = [];
      if (idsRaw !== undefined && idsRaw !== null) {
        for (let k = 0; k < idsRaw.length; k++) {
          ids.push(`${idsRaw[k]}`);
        }
      }
      items.push({
        workspaceId: `${one['workspaceId']}`,
        path: `${one['path']}`,
        title: `${one['title']}`,
        sessionIds: ids
      });
    }
    return {
      ok: true,
      items: items,
      archived: toStringArray(base['archivedSessionIds']),
      pinned: toStringArray(base['pinnedSessionIds']),
      detail: `工作区 ${items.length} 个`
    };
  } catch (error) {
    return emptyState('分组视图解析失败');
  }
}

function toStringArray(raw: Object | undefined): string[] {
  const out: string[] = [];
  if (raw === undefined || raw === null) {
    return out;
  }
  const arr = raw as Object[];
  for (let i = 0; i < arr.length; i++) {
    out.push(`${arr[i]}`);
  }
  return out;
}

/** 规整路径用于比较（Windows 下不区分大小写、容忍尾部斜杠） */
function normalizePath(p: string): string {
  let out: string = p.trim();
  while (out.length > 0 && (out.endsWith('\\') || out.endsWith('/'))) {
    out = out.substring(0, out.length - 1);
  }
  return out.toLowerCase();
}

/** 找 `cwd` 对应的工作区（找不到返回 undefined） */
export function workspaceForCwd(state: WorkspaceState, cwd: string): WorkspaceView | undefined {
  const want: string = normalizePath(cwd);
  for (let i = 0; i < state.items.length; i++) {
    if (normalizePath(state.items[i].path) === want) {
      return state.items[i];
    }
  }
  return undefined;
}

/**
 * 按官方口径过滤并排序：
 * 仅该工作区的会话 − 归档 − 子 agent −（非当前的空会话）；顺序 = 置顶优先 + 最近活动倒序。
 * `state` 取不到（网络/超时）时**退回原样**（只是把子 agent 与归档尽力剔掉），不让列表变空。
 */
export function visibleRows(rows: SessionRow[], state: WorkspaceState, cwd: string,
  currentId: string): SessionRow[] {
  const archived: string[] = state.archived;
  const pinned: string[] = state.pinned;
  const group: WorkspaceView | undefined = state.ok ? workspaceForCwd(state, cwd) : undefined;
  const keep: SessionRow[] = [];
  for (let i = 0; i < rows.length; i++) {
    const row: SessionRow = rows[i];
    if (row.origin === 'subagent') {
      continue;
    }
    if (row.blank && row.sessionId !== currentId) {
      continue;
    }
    if (archived.indexOf(row.sessionId) >= 0) {
      continue;
    }
    if (group !== undefined && group.sessionIds.indexOf(row.sessionId) < 0) {
      continue;
    }
    keep.push(row);
  }
  keep.sort((a: SessionRow, b: SessionRow): number => {
    const pa: number = pinned.indexOf(a.sessionId);
    const pb: number = pinned.indexOf(b.sessionId);
    if (pa >= 0 && pb >= 0) {
      return pa - pb;
    }
    if (pa >= 0) {
      return -1;
    }
    if (pb >= 0) {
      return 1;
    }
    return b.updatedAtMs - a.updatedAtMs;
  });
  return keep;
}
