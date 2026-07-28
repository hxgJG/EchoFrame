import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import AbilityAware from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityAware';
import { AbilityPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';

interface BackupInfoPayload {
  path: string;
  updatedAtMs: number;
}

const CHANNEL_NAME = 'lumio/app_storage';
const PREFERENCES_NAME = 'lumio_state';
const BACKUP_KEY = 'backup_json';
const BACKUP_UPDATED_AT_KEY = 'backup_updated_at';

export default class LumioAppStoragePlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private abilityContext: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'LumioAppStoragePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityContext = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.abilityContext = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'loadPartition':
        this.loadPartition(call, result);
        break;
      case 'savePartition':
        this.savePartition(call, result);
        break;
      case 'createBackup':
        this.createBackup(call, result);
        break;
      case 'restoreLatestBackup':
        this.restoreLatestBackup(result);
        break;
      case 'latestBackup':
        this.latestBackup(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private async loadPartition(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const partition: string = call.argument('partition') as string;
      const key = this.partitionKey(partition);
      if (key === null) {
        result.error('invalid_partition', '未知的应用存储分区。', null);
        return;
      }
      const store = await this.getStore();
      const json = await store.get(key, '') as string;
      result.success(this.decodeObject(json));
    } catch (error) {
      this.reportError(result, 'load_failed', '读取 HarmonyOS 应用状态失败。', error);
    }
  }

  private async savePartition(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const partition: string = call.argument('partition') as string;
      const key = this.partitionKey(partition);
      if (key === null) {
        result.error('invalid_partition', '未知的应用存储分区。', null);
        return;
      }
      const value: Object = call.argument('value') as Object;
      const store = await this.getStore();
      await store.put(key, JSON.stringify(value));
      await store.flush();
      result.success(null);
    } catch (error) {
      this.reportError(result, 'save_failed', '保存 HarmonyOS 应用状态失败。', error);
    }
  }

  private async createBackup(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const updatedAtMs = Date.now();
      const store = await this.getStore();
      await store.put(BACKUP_KEY, JSON.stringify(call.args));
      await store.put(BACKUP_UPDATED_AT_KEY, updatedAtMs);
      await store.flush();
      result.success(this.backupInfo(updatedAtMs));
    } catch (error) {
      this.reportError(result, 'backup_failed', '创建 HarmonyOS 应用内备份失败。', error);
    }
  }

  private async restoreLatestBackup(result: MethodResult): Promise<void> {
    try {
      const store = await this.getStore();
      const json = await store.get(BACKUP_KEY, '') as string;
      result.success(this.decodeObject(json));
    } catch (error) {
      this.reportError(result, 'restore_failed', '恢复 HarmonyOS 应用内备份失败。', error);
    }
  }

  private async latestBackup(result: MethodResult): Promise<void> {
    try {
      const store = await this.getStore();
      const updatedAtMs = await store.get(BACKUP_UPDATED_AT_KEY, 0) as number;
      result.success(updatedAtMs > 0 ? this.backupInfo(updatedAtMs) : null);
    } catch (error) {
      this.reportError(result, 'backup_info_failed', '读取 HarmonyOS 备份信息失败。', error);
    }
  }

  private async getStore(): Promise<preferences.Preferences> {
    if (this.abilityContext === null) {
      throw new Error('HarmonyOS Ability 上下文尚未就绪。');
    }
    return preferences.getPreferences(this.abilityContext, PREFERENCES_NAME);
  }

  private decodeObject(json: string): Object | null {
    if (json.length === 0) {
      return null;
    }
    const value: Object = JSON.parse(json);
    return typeof value === 'object' && value !== null ? value : null;
  }

  private backupInfo(updatedAtMs: number): BackupInfoPayload {
    return {
      path: `HarmonyOS 应用存储/lumio-backup-${updatedAtMs}.json`,
      updatedAtMs: updatedAtMs,
    };
  }

  private partitionKey(partition: string): string | null {
    switch (partition) {
      case 'session':
      case 'library':
      case 'playlists':
        return `state_${partition}`;
      default:
        return null;
    }
  }

  private reportError(
    result: MethodResult,
    code: string,
    fallbackMessage: string,
    error: Object,
  ): void {
    const message = error instanceof Error && error.message.length > 0
      ? error.message
      : fallbackMessage;
    result.error(code, message, null);
  }
}
