import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import fs from '@ohos.file.fs';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@ohos.base';
import { SurfaceTextureEntry, TextureRegistry } from '@ohos/flutter_ohos/src/main/ets/view/TextureRegistry';

const CHANNEL_NAME = 'lumio/playback';

export default class LumioPlaybackPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private textureRegistry: TextureRegistry | null = null;
  private textureEntry: SurfaceTextureEntry | null = null;
  private textureId: number | null = null;
  private avPlayer: media.AVPlayer | null = null;
  private mediaId: string = '';
  private mediaKind: string = 'audio';
  private pendingPositionMs: number = 0;
  private playbackSpeed: number = 1.0;
  private volumeScale: number = 1.0;
  private playResult: MethodResult | null = null;
  private playResultCompleted: boolean = false;
  private sourceFd: number = -1;

  getUniqueClassName(): string {
    return 'LumioPlaybackPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.textureRegistry = binding.getTextureRegistry();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.releaseCurrent();
    this.textureRegistry = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'play':
        this.play(call, result);
        break;
      case 'pause':
        this.pause(result);
        break;
      case 'resume':
        this.resume(result);
        break;
      case 'seek':
        this.seek(call, result);
        break;
      case 'setSpeed':
        this.setSpeed(call, result);
        break;
      case 'setVolumeScale':
        this.setVolumeScale(call, result);
        break;
      case 'stop':
        this.stop(result);
        break;
      case 'position':
        result.success(this.avPlayer?.currentTime ?? 0);
        break;
      case 'enterPictureInPicture':
      case 'adjustBrightness':
      case 'adjustVolume':
      case 'share':
      case 'shareMany':
      case 'setEqualizerPreset':
      case 'setCrossfadeDuration':
      case 'setShuffleEnabled':
      case 'setRepeatMode':
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private async play(call: MethodCall, result: MethodResult): Promise<void> {
    const path = this.stringArgument(call, 'path');
    if (path.length === 0) {
      result.error('invalidArgument', '缺少媒体文件路径。', null);
      return;
    }

    this.releaseCurrent();
    this.mediaId = this.stringArgument(call, 'mediaId');
    this.mediaKind = this.stringArgument(call, 'kind');
    this.pendingPositionMs = this.numberArgument(call, 'positionMs');
    this.playResult = result;
    this.playResultCompleted = false;

    try {
      if (this.mediaKind === 'video') {
        this.prepareTexture();
      }
      this.avPlayer = await media.createAVPlayer();
      this.bindPlayerEvents();
      this.setPlayerSource(path);
    } catch (error) {
      this.completePlayWithError(this.errorMessage(error, 'HarmonyOS 播放启动失败。'));
    }
  }

  private prepareTexture(): void {
    if (this.textureRegistry === null) {
      throw new Error('HarmonyOS TextureRegistry 尚未就绪。');
    }
    this.textureId = this.textureRegistry.getTextureId();
    this.textureEntry = this.textureRegistry.registerTexture(this.textureId);
  }

  private setPlayerSource(path: string): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      this.sourceFd = file.fd;
      player.fdSrc = { fd: this.sourceFd };
    } catch (_error) {
      player.url = path;
    }
  }

  private bindPlayerEvents(): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }

    player.on('stateChange', async (state: media.AVPlayerState) => {
      const current = this.avPlayer;
      if (current === null) {
        return;
      }
      try {
        switch (state) {
          case 'initialized':
            if (this.textureEntry !== null) {
              current.surfaceId = this.textureEntry.getSurfaceId().toString();
            }
            await current.prepare();
            break;
          case 'prepared':
            current.setVolume(this.volumeScale);
            this.applySpeed(current);
            if (this.pendingPositionMs > 0) {
              current.seek(this.pendingPositionMs, media.SeekMode.SEEK_CLOSEST);
            }
            await current.play();
            this.completePlaySuccess();
            break;
          case 'completed':
            this.channel?.invokeMethod('completed', { mediaId: this.mediaId });
            break;
          case 'error':
            this.channel?.invokeMethod('error', {
              mediaId: this.mediaId,
              message: 'HarmonyOS 播放器进入错误状态。',
            });
            this.completePlayWithError('HarmonyOS 播放器进入错误状态。');
            break;
          default:
            break;
        }
      } catch (error) {
        const message = this.errorMessage(error, 'HarmonyOS 播放状态处理失败。');
        this.channel?.invokeMethod('error', { mediaId: this.mediaId, message: message });
        this.completePlayWithError(message);
      }
    });

    player.on('endOfStream', () => {
      this.channel?.invokeMethod('completed', { mediaId: this.mediaId });
    });

    player.on('error', (error: BusinessError) => {
      const message = this.errorMessage(error, 'HarmonyOS 播放失败。');
      this.channel?.invokeMethod('error', { mediaId: this.mediaId, message: message });
      this.completePlayWithError(message);
    });
  }

  private completePlaySuccess(): void {
    if (this.playResult === null || this.playResultCompleted) {
      return;
    }
    this.playResultCompleted = true;
    this.playResult.success({
      textureId: this.mediaKind === 'video' ? this.textureId : null,
    });
    this.playResult = null;
  }

  private completePlayWithError(message: string): void {
    if (this.playResult !== null && !this.playResultCompleted) {
      this.playResultCompleted = true;
      this.playResult.error('playbackFailed', message, null);
      this.playResult = null;
      return;
    }
    this.channel?.invokeMethod('error', { mediaId: this.mediaId, message: message });
  }

  private async pause(result: MethodResult): Promise<void> {
    try {
      await this.avPlayer?.pause();
      result.success(null);
    } catch (error) {
      result.error('pauseFailed', this.errorMessage(error, '暂停失败。'), null);
    }
  }

  private async resume(result: MethodResult): Promise<void> {
    try {
      await this.avPlayer?.play();
      result.success(null);
    } catch (error) {
      result.error('resumeFailed', this.errorMessage(error, '恢复播放失败。'), null);
    }
  }

  private seek(call: MethodCall, result: MethodResult): void {
    try {
      const positionMs = this.numberArgument(call, 'positionMs');
      this.pendingPositionMs = positionMs;
      this.avPlayer?.seek(positionMs, media.SeekMode.SEEK_CLOSEST);
      result.success(null);
    } catch (error) {
      result.error('seekFailed', this.errorMessage(error, '跳转进度失败。'), null);
    }
  }

  private setSpeed(call: MethodCall, result: MethodResult): void {
    try {
      this.playbackSpeed = this.numberArgument(call, 'speed', 1.0);
      if (this.avPlayer !== null) {
        this.applySpeed(this.avPlayer);
      }
      result.success(null);
    } catch (error) {
      result.error('setSpeedFailed', this.errorMessage(error, '设置播放速度失败。'), null);
    }
  }

  private setVolumeScale(call: MethodCall, result: MethodResult): void {
    try {
      this.volumeScale = this.clamp(this.numberArgument(call, 'scale', 1.0), 0.0, 1.0);
      this.avPlayer?.setVolume(this.volumeScale);
      result.success(null);
    } catch (error) {
      result.error('setVolumeFailed', this.errorMessage(error, '设置音量失败。'), null);
    }
  }

  private stop(result: MethodResult): void {
    this.releaseCurrent();
    result.success(null);
  }

  private applySpeed(player: media.AVPlayer): void {
    player.setSpeed(this.speedEnum(this.playbackSpeed));
  }

  private speedEnum(speed: number): media.PlaybackSpeed {
    if (speed <= 0.6) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (speed <= 0.9) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (speed <= 1.1) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (speed <= 1.35) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (speed <= 1.6) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    if (speed <= 1.9) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }

  private releaseCurrent(): void {
    const player = this.avPlayer;
    const fd = this.sourceFd;
    this.avPlayer = null;
    this.sourceFd = -1;
    this.playResult = null;
    this.playResultCompleted = false;
    if (player !== null) {
      player.release().then(() => {
        this.closeSourceFd(fd);
      }).catch((_error: BusinessError) => {
        this.closeSourceFd(fd);
      });
    } else {
      this.closeSourceFd(fd);
    }
    if (this.textureId !== null) {
      this.textureRegistry?.unregisterTexture(this.textureId);
    }
    this.textureEntry = null;
    this.textureId = null;
  }

  private closeSourceFd(fd: number): void {
    if (fd < 0) {
      return;
    }
    try {
      fs.closeSync(fd);
    } catch (_error) {
    }
  }

  private stringArgument(call: MethodCall, key: string): string {
    const value = call.argument(key) as string | number | boolean | null | undefined;
    return value === null || value === undefined ? '' : String(value);
  }

  private numberArgument(call: MethodCall, key: string, fallback: number = 0): number {
    const value = call.argument(key) as number | string | null | undefined;
    if (typeof value === 'number') {
      return value;
    }
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  private clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }

  private errorMessage(error: Object, fallback: string): string {
    const businessError = error as BusinessError;
    if (businessError.message !== undefined && businessError.message.length > 0) {
      return businessError.message;
    }
    return fallback;
  }
}
