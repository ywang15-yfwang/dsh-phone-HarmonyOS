import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";

/**
 * 工件目录（host 半边）：
 *  - 目录只在运行时解析（配置 / 环境变量 / cwd），代码里不留任何本机路径；
 *  - 只列/读 `.html`，名字必须是单层文件名，拒绝路径分隔符与 `..`；
 *  - 返回标题取文件里的 <title>，没有就用文件名。
 */
export function resolveArtifactsDir(configured) {
  if (typeof configured === "string" && configured.trim() !== "") return resolve(configured.trim());
  if (typeof process.env.DSH_ARTIFACTS_DIR === "string" && process.env.DSH_ARTIFACTS_DIR.trim() !== "") {
    return resolve(process.env.DSH_ARTIFACTS_DIR.trim());
  }
  const cwd = process.cwd();
  const candidates = [resolve(cwd, "artifacts"), resolve(cwd, "..", "artifacts")];
  for (const one of candidates) {
    try {
      if (statSync(one).isDirectory()) return one;
    } catch {
      // 继续找
    }
  }
  return candidates[0];
}

export function createArtifactsApi(directory) {
  const root = resolve(directory);

  function safeName(name) {
    if (typeof name !== "string" || name.length === 0 || name.length > 200) return null;
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.html$/.test(name)) return null;
    return name;
  }

  function titleOf(file, fallback) {
    try {
      const head = readFileSync(file, "utf8").slice(0, 4096);
      const match = head.match(/<title>([\s\S]*?)<\/title>/i);
      if (match !== null) {
        const title = match[1].replace(/\s+/g, " ").trim();
        if (title.length > 0) return title.slice(0, 160);
      }
    } catch {
      // 读不到就用文件名
    }
    return fallback.replace(/\.html$/i, "");
  }

  function list() {
    let names;
    try {
      names = readdirSync(root);
    } catch {
      return { ok: false, error: "no-artifacts-dir", items: [] };
    }
    const items = [];
    for (const name of names) {
      if (safeName(name) === null) continue;
      const file = resolve(root, name);
      try {
        const stat = statSync(file);
        if (!stat.isFile()) continue;
        items.push({ name, title: titleOf(file, name), updatedAt: stat.mtimeMs, bytes: stat.size });
      } catch {
        // 单个文件跳过
      }
    }
    items.sort((a, b) => b.updatedAt - a.updatedAt);
    return { ok: true, dir: root, items };
  }

  function read(name) {
    const safe = safeName(name);
    if (safe === null) return null;
    const file = resolve(root, safe);
    if (dirname(file) !== root) return null;
    try {
      if (!statSync(file).isFile()) return null;
      return readFileSync(file, "utf8");
    } catch {
      return null;
    }
  }

  return { list, read };
}
