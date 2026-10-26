import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'HUKS';

/** HUKS 里的密钥别名（只在本设备、本应用可见；卸载即失） */
const KEY_ALIAS: string = 'dsh_ssh_pri_2026';
/** 密文格式版本前缀 */
const BLOB_PREFIX: string = 'v1';

function param(tag: huks.HuksTag, value: number | Uint8Array): huks.HuksParam {
  return { tag: tag, value: value } as huks.HuksParam;
}

/** 生成密钥时用的属性（AES-256-CBC-PKCS7，支持加解密） */
function genProperties(): huks.HuksParam[] {
  return [
    param(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    param(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    param(huks.HuksTag.HUKS_TAG_PURPOSE,
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT),
    param(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_CBC),
    param(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_PKCS7)
  ];
}

function workProperties(purpose: number, iv: Uint8Array): huks.HuksParam[] {
  return [
    param(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    param(huks.HuksTag.HUKS_TAG_PURPOSE, purpose),
    param(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_CBC),
    param(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_PKCS7),
    param(huks.HuksTag.HUKS_TAG_IV, iv)
  ];
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function toHex(bytes: Uint8Array): string {
  let s: string = '';
  for (let i = 0; i < bytes.length; i++) {
    s += bytes[i].toString(16).padStart(2, '0');
  }
  return s;
}

function fromHexText(text: string): Uint8Array {
  const clean: string = text.length % 2 === 1 ? `0${text}` : text;
  const out: Uint8Array = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function randomBytes(n: number): Uint8Array {
  // 加密私钥的 IV 必须是密码学随机（Math.random 可预测）
  try {
    const seed: Uint8Array = cryptoFramework.createRandom().generateRandomSync(n).data;
    if (seed.length === n) {
      return seed;
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '系统随机源不可用，IV 退回弱随机');
  }
  const out: Uint8Array = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = Math.floor(Math.random() * 256);
  }
  return out;
}

/** 确保 HUKS 里有这把密钥（没有就生成） */
export async function ensureHuksKey(): Promise<boolean> {
  try {
    // isKeyItemExist 在"不存在"时抛 12000011（不是返回 false），以前直接当"HUKS 不可用"⇒ 主密钥永远不生成
    let exists: boolean = false;
    try {
      exists = await huks.hasKeyItem(KEY_ALIAS, { properties: [] } as huks.HuksOptions);
    } catch (checkError) {
      const ce = checkError as BusinessError;
      if (ce.code === 12000011) {
        exists = false;
      } else if (typeof huks.isKeyItemExist === 'function') {
        // 老版本没有 hasKeyItem：退回 isKeyItemExist，但要把"不存在"当成 false
        try {
          exists = await huks.isKeyItemExist(KEY_ALIAS, { properties: [] } as huks.HuksOptions);
        } catch (legacyError) {
          const le = legacyError as BusinessError;
          if (le.code !== 12000011) {
            throw legacyError as Error;
          }
          exists = false;
        }
      } else {
        throw checkError as Error;
      }
    }
    if (exists) {
      return true;
    }
    await huks.generateKeyItem(KEY_ALIAS, { properties: genProperties() } as huks.HuksOptions);
    hilog.info(DOMAIN, TAG, '已生成 HUKS 主密钥');
    return true;
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'HUKS 不可用 code=%{public}d %{public}s', e.code ?? -1, e.message ?? '');
    return false;
  }
}

/**
 * 用 HUKS 主密钥加密一段字节，返回 `v1:<ivHex>:<cipherHex>`；失败返回 ''。
 * 主密钥永不离开 HUKS（应用只能"请它加解密"），所以偏好文件里只会有密文。
 */
export async function huksEncrypt(plain: Uint8Array): Promise<string> {
  try {
    if (!(await ensureHuksKey())) {
      return '';
    }
    const iv: Uint8Array = randomBytes(16);
    const initOptions: huks.HuksOptions = { properties: workProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, iv) };
    const session: huks.HuksSessionHandle = await huks.initSession(KEY_ALIAS, initOptions);
    try {
      const parts: Uint8Array[] = [];
      const upd: huks.HuksReturnResult = await huks.updateSession(session.handle, {
        properties: initOptions.properties, inData: plain
      } as huks.HuksOptions);
      if (upd.outData !== undefined) {
        parts.push(upd.outData);
      }
      const fin: huks.HuksReturnResult = await huks.finishSession(session.handle, {
        properties: initOptions.properties
      } as huks.HuksOptions);
      if (fin.outData !== undefined) {
        parts.push(fin.outData);
      }
      let cipher: Uint8Array = new Uint8Array(0);
      for (let i = 0; i < parts.length; i++) {
        cipher = concat(cipher, parts[i]);
      }
      return `${BLOB_PREFIX}:${toHex(iv)}:${toHex(cipher)}`;
    } catch (innerError) {
      // update/finish 抛错时 HUKS 会话句柄不会自己释放，必须 abort
      try {
        await huks.abortSession(session.handle, initOptions);
      } catch (abortError) {
        // 会话已结束
      }
      throw innerError as Error;
    }
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'HUKS 加密失败 code=%{public}d %{public}s', e.code ?? -1, e.message ?? '');
    return '';
  }
}

/** 解密 `v1:<ivHex>:<cipherHex>`；失败返回空数组 */
export async function huksDecrypt(blob: string): Promise<Uint8Array> {
  const empty: Uint8Array = new Uint8Array(0);
  try {
    const parts: string[] = blob.split(':');
    if (parts.length !== 3 || parts[0] !== BLOB_PREFIX) {
      return empty;
    }
    const iv: Uint8Array = fromHexText(parts[1]);
    const cipher: Uint8Array = fromHexText(parts[2]);
    const options: huks.HuksOptions = {
      properties: workProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, iv)
    };
    const session: huks.HuksSessionHandle = await huks.initSession(KEY_ALIAS, options);
    try {
      const collected: Uint8Array[] = [];
      const upd: huks.HuksReturnResult = await huks.updateSession(session.handle, {
        properties: options.properties, inData: cipher
      } as huks.HuksOptions);
      if (upd.outData !== undefined) {
        collected.push(upd.outData);
      }
      const fin: huks.HuksReturnResult = await huks.finishSession(session.handle, {
        properties: options.properties
      } as huks.HuksOptions);
      if (fin.outData !== undefined) {
        collected.push(fin.outData);
      }
      let plain: Uint8Array = new Uint8Array(0);
      for (let i = 0; i < collected.length; i++) {
        plain = concat(plain, collected[i]);
      }
      return plain;
    } catch (innerError) {
      try {
        await huks.abortSession(session.handle, options);
      } catch (abortError) {
        // 会话已结束
      }
      throw innerError as Error;
    }
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'HUKS 解密失败 code=%{public}d %{public}s', e.code ?? -1, e.message ?? '');
    return empty;
  }
}
