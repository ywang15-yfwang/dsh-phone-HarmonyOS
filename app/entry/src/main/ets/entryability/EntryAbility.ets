/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { sshKeys } from '../services/ssh/SshKeys';
import { cleanupTemp } from '../services/TempFiles';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 上次运行可能留下下载/打开/保存的中转文件：启动先清一遍
    cleanupTemp(this.context);
    // 启动时就把 SSH 身份准备好，并把**公钥**打进日志：
    // 装机/换机后电脑要认这一行（`administrators_authorized_keys`），有日志就不用
    // 让用户从界面上抄，也不用先触发一次注定失败的 SSH。
    // 身份现在走 HUKS（可能涉及一次解密/迁移），是异步的；启动时不阻塞界面
    sshKeys.ensure(this.context).then(() => {
      hilog.info(0xD001, 'SSHKEY', '身份公钥：%{public}s', sshKeys.publicKeyLine());
    }).catch((err: Error) => {
      hilog.error(0xD001, 'SSHKEY', '准备 SSH 身份失败：%{public}s', err.message);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 退出再清一次：打开中的文件此时已经没人读了
    cleanupTemp(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 第一页 = **登录页**（2026-10-25：暖色 Expressive 风格；不再单独做启动页）。
    // 登录页入网成功后进「网络里的电脑」；不再有"用本机 dsh"的免登录入口。
    windowStage.loadContent('pages/Welcome', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 登录页是浅暖色底：状态栏/导航栏用浅色 + 深色字（2026-10-25）
      try {
        const mainWindow = windowStage.getMainWindowSync();
        // 底部安全区/系统栏区域跟着页面底色走，避免一条白边（2026-10-25）
        mainWindow.setWindowLayoutFullScreen(true);
        mainWindow.setWindowBackgroundColor('#FFFBF5');
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#FFFBF5',
          statusBarContentColor: '#000000',
          navigationBarColor: '#FFFBF5',
          navigationBarContentColor: '#000000'
        });
        // 真实安全区（换机不写死）：状态栏/挖孔高度按系统实际值给页面用
        try {
          const density: number = display.getDefaultDisplaySync().densityPixels;
          const avoid = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const topVp: number = Math.round(avoid.topRect.height / density);
          const bottomVp: number = Math.round(avoid.bottomRect.height / density);
          AppStorage.setOrCreate('safeTopVp', topVp > 0 ? topVp : 40);
          AppStorage.setOrCreate('safeBottomVp', bottomVp > 0 ? bottomVp : 16);
          hilog.info(DOMAIN, 'testTag', 'safe area top=%{public}d bottom=%{public}d', topVp, bottomVp);
        } catch (avoidError) {
          AppStorage.setOrCreate('safeTopVp', 40);
          AppStorage.setOrCreate('safeBottomVp', 16);
          hilog.warn(DOMAIN, 'testTag', '读安全区失败，用默认 40/16');
        }
      } catch (barError) {
        hilog.warn(DOMAIN, 'testTag', '设置系统栏颜色失败');
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    const tick: number = (AppStorage.get('appForegroundTick') as number) ?? 0;
    AppStorage.setOrCreate('appForegroundTick', tick + 1);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  /**
   * **环境变了才做一次**（客户 2026-10-17：别拿时钟一直看环境有没有变）。
   * 系统字号/深浅色/语言这些一改，系统会回调这里；把 `fontSizeScale` 放进 AppStorage，
   * 并把事件发到 eventHub。
   */
  onConfigurationUpdated(config: Configuration): void {
    const scale: number = config.fontSizeScale ?? 0;
    AppStorage.setOrCreate('fontSizeScale', scale);
    hilog.info(DOMAIN, 'testTag', 'onConfigurationUpdated fontSizeScale=%{public}s', `${scale}`);
    this.context.eventHub.emit('fontScaleChanged');
  }
}

