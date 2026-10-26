import { util } from '@kit.ArkTS';

/**
 * SSH 线格式（RFC 4251）最小工具集 —— 只做我们用到的那几种类型。
 *
 * 为什么自己写：鸿蒙没有 SSH API，也没有 `Buffer`。SSH 的 string/mpint 全是
 * "4 字节大端长度 + 内容"，用 `Uint8Array` 拼装最直接。
 *
 * 纪律：**长度一律用 u32（无符号）**；mpint 必须先剥前导 0、再按最高位补 0 ——
 * 这两条错了会在服务端表现为 `Bad packet length`（本项目踩过）。
 */

export function utf8(text: string): Uint8Array {
  // ⚠️ 空串时系统的 encodeInto 返回 undefined（不是长度为 0 的数组），必须兜住——
  // KEXINIT 里有 4 个空名字表，这里不兜会在组包时炸
  if (text.length === 0) {
    return new Uint8Array(0);
  }
  return new util.TextEncoder().encodeInto(text);
}

export function text(bytes: Uint8Array): string {
  return new util.TextDecoder().decodeToString(bytes);
}

export function concat(parts: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (let i = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let at: number = 0;
  for (let i = 0; i < parts.length; i++) {
    out.set(parts[i], at);
    at += parts[i].length;
  }
  return out;
}

export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

export function hex(bytes: Uint8Array): string {
  let s: string = '';
  for (let i = 0; i < bytes.length; i++) {
    s += bytes[i].toString(16).padStart(2, '0');
  }
  return s;
}

export function fromHex(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(Math.floor(s.length / 2));
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(s.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** base64（公钥给用户复制用） */
export function base64(bytes: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(bytes);
}

/** 写端：byte / uint32 / string / 原样字节 */
export class W {
  private parts: Uint8Array[] = [];

  u8(v: number): W {
    this.parts.push(new Uint8Array([v & 0xff]));
    return this;
  }

  u32(v: number): W {
    const b: Uint8Array = new Uint8Array(4);
    b[0] = (v >>> 24) & 0xff;
    b[1] = (v >>> 16) & 0xff;
    b[2] = (v >>> 8) & 0xff;
    b[3] = v & 0xff;
    this.parts.push(b);
    return this;
  }

  raw(b: Uint8Array): W {
    this.parts.push(b);
    return this;
  }

  str(s: Uint8Array): W {
    this.u32(s.length);
    this.parts.push(s);
    return this;
  }

  strText(s: string): W {
    return this.str(utf8(s));
  }

  bytes(): Uint8Array {
    return concat(this.parts);
  }
}

/** 读端：任一笔读越界就抛，调用方当解析失败处理 */
export class R {
  private b: Uint8Array;
  private i: number = 0;

  constructor(b: Uint8Array) {
    this.b = b;
  }

  left(): number {
    return this.b.length - this.i;
  }

  u8(): number {
    if (this.i + 1 > this.b.length) {
      throw new Error('ssh read overflow u8');
    }
    return this.b[this.i++];
  }

  u32(): number {
    if (this.i + 4 > this.b.length) {
      throw new Error('ssh read overflow u32');
    }
    const v: number = ((this.b[this.i] << 24) >>> 0) + (this.b[this.i + 1] << 16) +
      (this.b[this.i + 2] << 8) + this.b[this.i + 3];
    this.i += 4;
    return v >>> 0;
  }

  raw(n: number): Uint8Array {
    if (this.i + n > this.b.length) {
      throw new Error('ssh read overflow raw');
    }
    const v: Uint8Array = this.b.slice(this.i, this.i + n);
    this.i += n;
    return v;
  }

  str(): Uint8Array {
    return this.raw(this.u32());
  }

  strText(): string {
    return text(this.str());
  }

  rest(): Uint8Array {
    return this.b.slice(this.i);
  }
}

/** SSH string 编码（含 4 字节长度） */
export function sshStr(s: Uint8Array): Uint8Array {
  return new W().str(s).bytes();
}

/** mpint 编码（内容，不含外层长度）：剥前导 0，最高位为 1 时补 0 */
export function mpint(body: Uint8Array): Uint8Array {
  let i: number = 0;
  while (i < body.length - 1 && body[i] === 0) {
    i++;
  }
  const trimmed: Uint8Array = body.slice(i);
  if ((trimmed[0] & 0x80) !== 0) {
    const out: Uint8Array = new Uint8Array(trimmed.length + 1);
    out.set(trimmed, 1);
    return out;
  }
  return trimmed;
}
