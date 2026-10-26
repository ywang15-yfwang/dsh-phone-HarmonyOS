import { http } from '@kit.NetworkKit';
import { pluginRequest, TextResult } from '../../services/net/DshNet';
import { pairTarget } from '../../services/PairTarget';
import { TransportTarget } from '../../channel/FileTransport';

export interface ArtifactItem {
  name: string;
  title: string;
  updatedAt: number;
  bytes: number;
}

/** 电脑上的工件列表（只列 .html） */
export async function listArtifacts(): Promise<ArtifactItem[]> {
  const base: TransportTarget = pairTarget();
  const res: TextResult = await pluginRequest(base.address, base.port, http.RequestMethod.GET, '/pair/artifacts');
  if (res.statusCode <= 0 || res.statusCode >= 300) {
    return [];
  }
  try {
    const root: Record<string, Object> = JSON.parse(res.body) as Record<string, Object>;
    const raw: Object | undefined = root['items'];
    if (!Array.isArray(raw)) {
      return [];
    }
    const items: ArtifactItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      const one: Record<string, Object> = raw[i] as Record<string, Object>;
      if (typeof one['name'] !== 'string') {
        continue;
      }
      items.push({
        name: one['name'] as string,
        title: typeof one['title'] === 'string' ? one['title'] as string : one['name'] as string,
        updatedAt: typeof one['updatedAt'] === 'number' ? one['updatedAt'] as number : 0,
        bytes: typeof one['bytes'] === 'number' ? one['bytes'] as number : 0
      });
    }
    return items;
  } catch (error) {
    return [];
  }
}

/** WebView 直接打开的 URL（插件口，tailnet 可达） */
export function artifactUrl(name: string): string {
  const base: TransportTarget = pairTarget();
  return `http://${base.address}:${base.port}/pair/artifact?name=${encodeURIComponent(name)}`;
}
