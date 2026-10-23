/*
 * 文件名：EntryAbility.ets
 * 功能：应用入口 Ability，负责加载首页、初始化全局状态、数据库与碳核算因子
 * 说明：
 *   1. AppState（AppStorage + PersistentStorage）必须在 UI 实例创建成功后才能初始化，
 *      因此放在 loadContent 回调里，而不是 onCreate；
 *   2. 数据库、因子库各自独立 try/catch，初始化失败只记日志，不阻塞首页展示。
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { DBUtil } from '../common/DBUtil';
import { CarbonCalculator } from '../utils/CarbonCalculator';
import { AppState } from '../model/AppState';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to load content, code=%{public}d, message=%{public}s',
          err.code, err.message);
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'Load content success');

      // API 12 限制：PersistentStorage 依赖 UI 实例，必须在 loadContent 回调中调用，
      // 早于该时机（如 onCreate）调用会导致持久化失效。
      // 这里完成 AppStorage 的 setOrCreate + 持久化注册 + 跨天重置。
      AppState.initGlobalState();

      // 全局状态就绪后，再初始化数据库与因子库（省份恢复会用到 AppState）
      this.initApp().catch((err: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'initApp failed: %{public}s', err.message);
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onForeground');
    // 回到前台时检查是否跨天（初始化完成前不处理，避免早于 persistProp 写 AppStorage）
    if (AppState.isInitialized()) {
      AppState.loadTodayPoint();
    }
  }

  onBackground(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onBackground');
  }

  /**
   * 初始化流程：
   *   1. 打开数据库并建表（失败时记录功能不可用，界面仍可运行）；
   *   2. 加载 rawfile 碳排放因子（失败时计算功能不可用）；
   *   3. 用 AppState 中恢复的省份 id 设置省级电网因子。
   */
  private async initApp(): Promise<void> {
    const dbReady: boolean = await DBUtil.initDB(this.context);
    if (!dbReady) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'database init failed, record feature unavailable');
    }

    let factorReady: boolean = false;
    try {
      await CarbonCalculator.getInstance().init(this.context);
      factorReady = true;
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'carbon factor init failed: %{public}s', message);
    }

    if (factorReady) {
      const provinceId: string = AppState.getSelectProvinceId();
      if (provinceId.length > 0 && !CarbonCalculator.getInstance().setProvince(provinceId)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stored province id is invalid: %{public}s', provinceId);
        AppState.setSelectProvinceId('');
      }
    }

    hilog.info(LOG_DOMAIN, LOG_TAG, 'app init finished, dbReady=%{public}s, todayPoint=%{public}d',
      String(dbReady), AppState.getTodayEarnPoint());
  }
}
