import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { W, base64, fromHex, hex } from './SshWire';
import { Ed25519Pair, ed25519Generate, ed25519Load } from './SshCrypto';
import { huksDecrypt, huksEncrypt } from './SshKeyStore';

const DOMAIN: number = 0xD001;
const TAG: string = 'SSHKEY';

const STORE_NAME: string = 'dsh_ssh';
const KEY_PUB: string = 'ed25519_pub_der';
/** 旧格式：私钥 DER 的 hex（**明文**）。迁移到 `KEY_PRI_ENC` 后会清空。 */
const KEY_PRI: string = 'ed25519_pri_der';
/** 新格式：`v1:<ivHex>:<cipherHex>`，主密钥在 HUKS 里，偏好文件里只有密文。 */
const KEY_PRI_ENC: string = 'ed25519_pri_enc';
const KEY_COMMENT: string = 'dsh-phone';

/**
 * 手机侧 SSH 身份（Ed25519）的**持久化 + 公钥出示**。
 *
 * 客户 2026-10-22 要求：**私钥不能在偏好文件里明文躺着** ⇒ 私钥 DER 用 HUKS 主密钥加密后存（`KEY_PRI_ENC`）；
 * 旧版本留下的明文（`KEY_PRI`）会在能加密并**验过解密往返**之后删掉 —— 加密不可用时保持原样，
 * 宁可保持现状也不能把人锁在门外（换新密钥 = 电脑上那把旧公钥立刻失效）。
 *
 * 口径：
 *  - 密钥**只生成在手机**，私钥不出设备；
 *  - 电脑侧只多出**一行公钥**（`administrators_authorized_keys`），没有常驻服务、没有密码；
 *  - 公钥文本由 `publicKeyLine()` 给出，用户复制一次即可。
 */
export class SshKeys {
  private pair: Ed25519Pair | undefined = undefined;
  private store: preferences.Preferences | undefined = undefined;

  /** 取（必要时生成/迁移）身份；`ctx` 用 UIAbility 的 context */
  async ensure(ctx: common.Context): Promise<Ed25519Pair> {
    if (this.pair !== undefined) {
      return this.pair;
    }
    const st: preferences.Preferences = this.open(ctx);
    const pubHex: string = st.getSync(KEY_PUB, '') as string;
    const priEnc: string = st.getSync(KEY_PRI_ENC, '') as string;
    const priHex: string = st.getSync(KEY_PRI, '') as string;

    // ① 新格式：HUKS 密文
    if (pubHex.length > 0 && priEnc.length > 0) {
      const decrypted: Uint8Array = await huksDecrypt(priEnc);
      if (decrypted.length > 0) {
        try {
          this.pair = ed25519Load(fromHex(pubHex), decrypted);
          hilog.info(DOMAIN, TAG, '载入 SSH 身份（HUKS 加密存储）');
          return this.pair;
        } catch (error) {
          const e = error as BusinessError;
          hilog.warn(DOMAIN, TAG, 'HUKS 密文解出的私钥不可用：%{public}s', e.message);
        }
      }
    }

    // ② 旧格式：明文 hex（升级路径）
    if (pubHex.length > 0 && priHex.length > 0) {
      try {
        this.pair = ed25519Load(fromHex(pubHex), fromHex(priHex));
        hilog.info(DOMAIN, TAG, '载入 SSH 身份（旧明文格式）');
        await this.migrateToHuks(ctx, st, pubHex, priHex);
        return this.pair;
      } catch (error) {
        const e = error as BusinessError;
        hilog.warn(DOMAIN, TAG, '已存密钥解析失败，重新生成：%{public}s', e.message);
      }
    }

    // ③ 新建
    const made: Ed25519Pair = ed25519Generate();
    await this.persist(ctx, st, made);
    this.pair = made;
    hilog.info(DOMAIN, TAG, '已生成新的 SSH 身份（公钥 %{public}s…）', this.publicKeyLine().substring(0, 32));
    return made;
  }

  /** 把旧明文私钥迁到 HUKS：加密 → 解回来比对一致 → 才删明文 */
  private async migrateToHuks(ctx: common.Context, st: preferences.Preferences,
    pubHex: string, priHex: string): Promise<void> {
    try {
      const plain: Uint8Array = fromHex(priHex);
      const blob: string = await huksEncrypt(plain);
      if (blob.length === 0) {
        hilog.warn(DOMAIN, TAG, 'HUKS 不可用，私钥暂时保持明文（不影响使用）');
        return;
      }
      const roundTrip: Uint8Array = await huksDecrypt(blob);
      if (roundTrip.length !== plain.length) {
        hilog.warn(DOMAIN, TAG, 'HUKS 往返长度不一致，暂不删除明文');
        return;
      }
      for (let i = 0; i < plain.length; i++) {
        if (roundTrip[i] !== plain[i]) {
          hilog.warn(DOMAIN, TAG, 'HUKS 往返内容不一致，暂不删除明文');
          return;
        }
      }
      st.putSync(KEY_PRI_ENC, blob);
      st.putSync(KEY_PRI, '');
      st.flushSync();
      hilog.info(DOMAIN, TAG, '私钥已迁移到 HUKS 加密存储（明文已清除）');
    } catch (error) {
      const e = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '迁移到 HUKS 失败（保持明文）：%{public}s', e.message);
    }
  }

  /** 新生成的身份：能加密就只存密文，不能才退回明文（并明确记日志） */
  private async persist(ctx: common.Context, st: preferences.Preferences, made: Ed25519Pair): Promise<void> {
    st.putSync(KEY_PUB, hex(made.pubDer));
    const blob: string = await huksEncrypt(made.priDer);
    if (blob.length > 0) {
      const roundTrip: Uint8Array = await huksDecrypt(blob);
      let same: boolean = roundTrip.length === made.priDer.length;
      if (same) {
        for (let i = 0; i < roundTrip.length; i++) {
          if (roundTrip[i] !== made.priDer[i]) {
            same = false;
            break;
          }
        }
      }
      if (same) {
        st.putSync(KEY_PRI_ENC, blob);
        st.putSync(KEY_PRI, '');
        st.flushSync();
        hilog.info(DOMAIN, TAG, '新身份已用 HUKS 加密存储');
        return;
      }
      hilog.warn(DOMAIN, TAG, 'HUKS 往返校验失败，退回明文存储（功能优先）');
    }
    st.putSync(KEY_PRI_ENC, '');
    st.putSync(KEY_PRI, hex(made.priDer));
    // 旧密文必须清掉：手机上不能同时留着上一把（可能已解不开）的私钥
    // 落盘用同步 flush：异步 flush 没写完就被杀 ⇒ 下次启动重新生成、电脑上旧公钥失效
    st.flushSync();
  }

  /** OpenSSH 授权行：`ssh-ed25519 AAAAC3... dsh-phone` */
  publicKeyLine(): string {
    if (this.pair === undefined) {
      return '';
    }
    const blob: Uint8Array = new W().strText('ssh-ed25519').str(this.pair.rawPub).bytes();
    return `ssh-ed25519 ${base64(blob)} ${KEY_COMMENT}`;
  }

  private open(ctx: common.Context): preferences.Preferences {
    if (this.store !== undefined) {
      return this.store;
    }
    this.store = preferences.getPreferencesSync(ctx, { name: STORE_NAME } as preferences.Options);
    return this.store;
  }
}

/** 全应用共用一个（密钥只在内存留一份） */
export const sshKeys: SshKeys = new SshKeys();
