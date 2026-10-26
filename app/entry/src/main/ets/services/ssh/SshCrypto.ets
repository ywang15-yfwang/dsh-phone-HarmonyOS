import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { concat, equalBytes } from './SshWire';

/**
 * SSH 需要的那几样原语，全部走系统 `cryptoFramework`（**不引入第三方库**）：
 *   - SHA-256（交换哈希 H、KDF）
 *   - HMAC-SHA256（包 MAC）
 *   - AES-128/256-CTR（**流式**：同一个 Cipher 实例连续 update，计数器自己走）
 *   - X25519（curve25519-sha256 的 ECDH）
 *   - Ed25519（客户端身份公钥的签名）
 *
 * 三条硬约束（实测口径，写在这里免得后人再踩）：
 *  ① **CTR 必须复用同一个 Cipher 实例**：`updateSync` 的次数/分片自由，但每 new 一次
 *     实例都从 IV 重新起算 ⇒ 解第二个包就错位。
 *  ② X25519 的密钥在系统里是 DER（SPKI/PKCS#8），**裸 32 字节在 DER 尾部**；
 *     协商出来的 shared secret 是裸 32 字节。
 *  ③ Ed25519 没有摘要（`signSync` 直接吃原文），签名结果是裸 64 字节。
 */

const TAG: string = 'SshCrypto';

export function sha256(parts: Uint8Array[]): Uint8Array {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  for (let i = 0; i < parts.length; i++) {
    md.updateSync({ data: parts[i] } as cryptoFramework.DataBlob);
  }
  return md.digestSync().data;
}

export function hmacSha256(key: Uint8Array, parts: Uint8Array[]): Uint8Array {
  const sym: cryptoFramework.SymKey =
    cryptoFramework.createSymKeyGenerator('HMAC').convertKeySync({ data: key } as cryptoFramework.DataBlob);
  const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
  mac.initSync(sym);
  for (let i = 0; i < parts.length; i++) {
    mac.updateSync({ data: parts[i] } as cryptoFramework.DataBlob);
  }
  return mac.doFinalSync().data;
}

/** 恒定时间比较（MAC 用；避免提前返回泄露差异位置） */
export function safeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff: number = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

/**
 * AES-CTR 流式加/解密器：`transform` 可任意切分，计数器在实例内部连续走。
 * SSH 的 CTR 一个方向一个实例（收/发各一个），**不能混用**。
 */
export class AesCtr {
  private cipher: cryptoFramework.Cipher;

  constructor(key: Uint8Array, iv: Uint8Array, encrypt: boolean) {
    const algName: string = key.length === 32 ? 'AES256' : 'AES128';
    const keyAlg: string = algName;
    const sym: cryptoFramework.SymKey =
      cryptoFramework.createSymKeyGenerator(keyAlg).convertKeySync({ data: key } as cryptoFramework.DataBlob);
    const c: cryptoFramework.Cipher = cryptoFramework.createCipher(`${algName}|CTR|NoPadding`);
    const spec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: iv } as cryptoFramework.DataBlob
    };
    c.initSync(encrypt ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE, sym, spec);
    this.cipher = c;
  }

  transform(input: Uint8Array): Uint8Array {
    if (input.length === 0) {
      return new Uint8Array(0);
    }
    return this.cipher.updateSync({ data: input } as cryptoFramework.DataBlob).data;
  }
}

// ---------- X25519 ---------------------------------------------------------

const SPKI_X25519_PREFIX: number[] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00];

export function x25519Spki(raw32: Uint8Array): Uint8Array {
  return concat([new Uint8Array(SPKI_X25519_PREFIX), raw32]);
}

/** Ed25519 的 SPKI 前缀（OID 1.3.101.112），用于**校验服务端主机签名** */
const SPKI_ED25519_PREFIX: number[] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];

/** 裸 32 字节 Ed25519 公钥 → SPKI DER（`ed25519Verify` 要 DER） */
export function ed25519SpkiFromRaw(raw32: Uint8Array): Uint8Array {
  return concat([new Uint8Array(SPKI_ED25519_PREFIX), raw32]);
}

/** 从 DER 里取裸 32 字节（SPKI 尾 / PKCS#8 尾都是它） */
export function derTail32(der: Uint8Array): Uint8Array {
  if (der.length < 32) {
    throw new Error('der too short: ' + der.length);
  }
  return der.slice(der.length - 32);
}

export interface X25519Pair {
  priKey: cryptoFramework.PriKey;
  rawPub: Uint8Array;
}

export function x25519Generate(): X25519Pair {
  const kp: cryptoFramework.KeyPair = cryptoFramework.createAsyKeyGenerator('X25519').generateKeyPairSync();
  return {
    priKey: kp.priKey,
    rawPub: derTail32(kp.pubKey.getEncoded().data)
  };
}

/** 与服务端的临时公钥做 ECDH，返回裸 32 字节 shared secret */
export function x25519Secret(priKey: cryptoFramework.PriKey, rawPeerPub: Uint8Array): Uint8Array {
  const peer: cryptoFramework.PubKey =
    cryptoFramework.createAsyKeyGenerator('X25519').convertKeySync(
      { data: x25519Spki(rawPeerPub) } as cryptoFramework.DataBlob, null).pubKey;
  const secret: cryptoFramework.DataBlob =
    cryptoFramework.createKeyAgreement('X25519').generateSecretSync(priKey, peer);
  if (secret.data.length !== 32) {
    throw new Error(`unexpected x25519 secret length ${secret.data.length}`);
  }
  return secret.data;
}

// ---------- Ed25519 --------------------------------------------------------

export interface Ed25519Pair {
  pubDer: Uint8Array;
  priDer: Uint8Array;
  priKey: cryptoFramework.PriKey;
  rawPub: Uint8Array;
}

export function ed25519Generate(): Ed25519Pair {
  const kp: cryptoFramework.KeyPair = cryptoFramework.createAsyKeyGenerator('Ed25519').generateKeyPairSync();
  return {
    pubDer: kp.pubKey.getEncoded().data,
    priDer: kp.priKey.getEncoded().data,
    priKey: kp.priKey,
    rawPub: derTail32(kp.pubKey.getEncoded().data)
  };
}

/** 从持久化的 DER 还原（App 重装/重启后复用同一身份） */
export function ed25519Load(pubDer: Uint8Array, priDer: Uint8Array): Ed25519Pair {
  const kp: cryptoFramework.KeyPair =
    cryptoFramework.createAsyKeyGenerator('Ed25519').convertKeySync(
      { data: pubDer } as cryptoFramework.DataBlob, { data: priDer } as cryptoFramework.DataBlob);
  return {
    pubDer: pubDer,
    priDer: priDer,
    priKey: kp.priKey,
    rawPub: derTail32(kp.pubKey.getEncoded().data)
  };
}

/** Ed25519 签名（裸 64 字节）；Sign 实例**不能重复 initSync**，每次新建 */
export function ed25519Sign(priKey: cryptoFramework.PriKey, data: Uint8Array): Uint8Array {
  const sign: cryptoFramework.Sign = cryptoFramework.createSign('Ed25519');
  sign.initSync(priKey);
  return sign.signSync({ data: data } as cryptoFramework.DataBlob).data;
}

/** 自检用：签名能不能被同一把公钥验过 */
export function ed25519Verify(pubDer: Uint8Array, data: Uint8Array, sig: Uint8Array): boolean {
  const pub: cryptoFramework.PubKey =
    cryptoFramework.createAsyKeyGenerator('Ed25519').convertKeySync({ data: pubDer } as cryptoFramework.DataBlob, null).pubKey;
  const v: cryptoFramework.Verify = cryptoFramework.createVerify('Ed25519');
  v.initSync(pub);
  return v.verifySync({ data: data } as cryptoFramework.DataBlob, { data: sig } as cryptoFramework.DataBlob);
}

/** 单元自检：X25519 双方协商一致 + AES-CTR 分片等价 + HMAC 与已知向量一致 */
export function cryptoSelfTest(): string {
  const problems: string[] = [];
  // X25519：A、B 两对密钥协商结果应相同
  const a: X25519Pair = x25519Generate();
  const b: X25519Pair = x25519Generate();
  const s1: Uint8Array = x25519Secret(a.priKey, b.rawPub);
  const s2: Uint8Array = x25519Secret(b.priKey, a.rawPub);
  if (!equalBytes(s1, s2)) {
    problems.push('X25519 协商两侧不一致');
  }
  // AES-CTR：一次解开 vs 分三段解开，结果必须相同
  const key: Uint8Array = sha256([new Uint8Array([1, 2, 3])]);
  const iv: Uint8Array = sha256([new Uint8Array([4, 5, 6])]).slice(0, 16);
  const plain: Uint8Array = new Uint8Array(100);
  for (let i = 0; i < plain.length; i++) {
    plain[i] = i;
  }
  const once: Uint8Array = new AesCtr(key, iv, true).transform(plain);
  const enc: AesCtr = new AesCtr(key, iv, true);
  const split: Uint8Array = concat([enc.transform(plain.slice(0, 7)), enc.transform(plain.slice(7, 40)), enc.transform(plain.slice(40))]);
  if (!equalBytes(once, split)) {
    problems.push('AES-CTR 分片不等价');
  }
  const dec: AesCtr = new AesCtr(key, iv, false);
  const back: Uint8Array = concat([dec.transform(once.slice(0, 7)), dec.transform(once.slice(7))]);
  if (!equalBytes(back, plain)) {
    problems.push('AES-CTR 解不回原文');
  }
  // HMAC-SHA256 RFC 4231 用例 1
  const mac: Uint8Array = hmacSha256(new Uint8Array(20).fill(0x0b), [new Uint8Array([0x48, 0x69, 0x20, 0x54, 0x68, 0x65, 0x72, 0x65])]);
  const want: string = 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7';
  let got: string = '';
  for (let i = 0; i < mac.length; i++) {
    got += mac[i].toString(16).padStart(2, '0');
  }
  if (got !== want) {
    problems.push(`HMAC-SHA256 与 RFC4231 不符（${got}）`);
  }
  // Ed25519：自签自验
  const ed: Ed25519Pair = ed25519Generate();
  const msg: Uint8Array = new Uint8Array([1, 2, 3, 4]);
  const sig: Uint8Array = ed25519Sign(ed.priKey, msg);
  if (sig.length !== 64) {
    problems.push(`Ed25519 签名长度 ${sig.length}`);
  }
  if (!ed25519Verify(ed.pubDer, msg, sig)) {
    problems.push('Ed25519 自验失败');
  }
  return problems.length === 0 ? 'ok' : problems.join('; ');
}

export const CRYPTO_TAG: string = TAG;
