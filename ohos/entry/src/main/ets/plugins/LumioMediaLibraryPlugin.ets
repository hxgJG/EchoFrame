import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@ohos.base';
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

interface MediaItemPayload {
  id: string;
  kind: string;
  title: string;
  artist: string;
  album: string;
  path: string;
  folder: string;
  durationMs: number;
  addedAtMs: number;
  sizeBytes: number;
  resolution: string;
  format: string;
}

interface ScanResultPayload {
  status: string;
  message: string;
  audioItems: Array<MediaItemPayload>;
  videoItems: Array<MediaItemPayload>;
}

interface FileFacts {
  sizeBytes: number;
  modifiedAtMs: number;
}

interface LyricsImportPayload {
  status: string;
  message: string;
  fileName: string;
  lyricsText: string;
}

const CHANNEL_NAME = 'lumio/media_library';
const PICKER_RESULT_MESSAGE = 'HarmonyOS 已按系统隐私策略导入用户选择的媒体。';
const MAX_SELECT_NUMBER = 500;
const MAX_LYRICS_FILE_BYTES = 2 * 1024 * 1024;

export default class LumioMediaLibraryPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private abilityContext: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'LumioMediaLibraryPlugin';
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
      case 'scan':
        this.scan(result);
        break;
      case 'restoreLastScan':
        result.success(this.emptyResult('HarmonyOS 媒体由用户选择导入，暂无平台侧扫描快照。'));
        break;
      case 'importLyrics':
        this.importLyrics(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private async importLyrics(result: MethodResult): Promise<void> {
    if (this.abilityContext === null) {
      result.error('unavailable', 'HarmonyOS Ability 上下文尚未就绪。', null);
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker(this.abilityContext);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.lrc'];
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        result.success(this.lyricsImportResult('cancelled', '已取消选择歌词文件。'));
        return;
      }
      const uri = uris[0];
      const fileName = this.displayNameFromUri(uri);
      if (this.extensionOf(fileName).toLowerCase() !== 'lrc') {
        result.success(this.lyricsImportResult('failed', '请选择 .lrc 格式的歌词文件。'));
        return;
      }
      const lyricsText = this.readLyricsText(uri);
      result.success(this.lyricsImportResult(
        'completed',
        '歌词文件已读取。',
        fileName,
        lyricsText,
      ));
    } catch (error) {
      if (this.isPickerCancelled(error)) {
        result.success(this.lyricsImportResult('cancelled', '已取消选择歌词文件。'));
        return;
      }
      result.success(this.lyricsImportResult(
        'failed',
        this.errorMessage(error, '歌词文件读取失败。'),
      ));
    }
  }

  private readLyricsText(uri: string): string {
    let fd = -1;
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const size = fs.statSync(fd).size;
      if (size > MAX_LYRICS_FILE_BYTES) {
        throw new Error('歌词文件不能超过 2 MB。');
      }
      const buffer = new ArrayBuffer(size);
      const bytesRead = fs.readSync(fd, buffer);
      const bytes = new Uint8Array(buffer, 0, bytesRead);
      const encoding = bytesRead >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE
        ? 'utf-16le'
        : bytesRead >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF
          ? 'utf-16be'
          : 'utf-8';
      return util.TextDecoder.create(encoding, { ignoreBOM: true }).decodeWithStream(bytes);
    } finally {
      if (fd >= 0) {
        this.closeFd(fd);
      }
    }
  }

  private lyricsImportResult(
    status: string,
    message: string,
    fileName: string = '',
    lyricsText: string = '',
  ): LyricsImportPayload {
    const payload: LyricsImportPayload = {
      status: status,
      message: message,
      fileName: fileName,
      lyricsText: lyricsText,
    };
    return payload;
  }

  private async scan(result: MethodResult): Promise<void> {
    if (this.abilityContext === null) {
      result.error('unavailable', 'HarmonyOS Ability 上下文尚未就绪。', null);
      return;
    }

    try {
      const audioUris = await this.pickAudioUris(this.abilityContext);
      const videoUris = await this.pickVideoUris();
      const audioItems = await this.urisToItems(audioUris, 'audio');
      const videoItems = await this.urisToItems(videoUris, 'video');
      if (audioItems.length === 0 && videoItems.length === 0) {
        const cancelledResult: ScanResultPayload = {
          status: 'cancelled',
          message: '未选择媒体，媒体库保持不变。',
          audioItems: [],
          videoItems: [],
        };
        result.success(cancelledResult);
        return;
      }
      const scanResult: ScanResultPayload = {
        status: 'completed',
        message: PICKER_RESULT_MESSAGE,
        audioItems: audioItems,
        videoItems: videoItems,
      };
      result.success(scanResult);
    } catch (error) {
      if (this.isPickerCancelled(error)) {
        const cancelledResult: ScanResultPayload = {
          status: 'cancelled',
          message: '已取消选择，媒体库未变更。',
          audioItems: [],
          videoItems: [],
        };
        result.success(cancelledResult);
        return;
      }
      const message = this.errorMessage(error, 'HarmonyOS 媒体选择失败。');
      const scanResult: ScanResultPayload = {
        status: 'failed',
        message: message,
        audioItems: [],
        videoItems: [],
      };
      result.success(scanResult);
    }
  }

  private async pickAudioUris(context: common.UIAbilityContext): Promise<Array<string>> {
    try {
      const audioPicker = new picker.AudioViewPicker(context);
      const options = new picker.AudioSelectOptions();
      options.maxSelectNumber = MAX_SELECT_NUMBER;
      return await audioPicker.select(options);
    } catch (error) {
      if (this.isPickerCancelled(error)) {
        return [];
      }
      throw new Error(this.errorMessage(error, 'HarmonyOS 音频选择失败。'));
    }
  }

  private async pickVideoUris(): Promise<Array<string>> {
    try {
      const videoPicker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
      options.maxSelectNumber = MAX_SELECT_NUMBER;
      const selected = await videoPicker.select(options);
      return selected.photoUris;
    } catch (error) {
      if (this.isPickerCancelled(error)) {
        return [];
      }
      throw new Error(this.errorMessage(error, 'HarmonyOS 视频选择失败。'));
    }
  }

  private async urisToItems(uris: Array<string>, kind: string): Promise<Array<MediaItemPayload>> {
    const uniqueUris = Array.from(new Set(uris));
    const items: Array<MediaItemPayload> = [];
    for (const uri of uniqueUris) {
      items.push(await this.uriToItem(uri, kind));
    }
    return items;
  }

  private async uriToItem(uri: string, kind: string): Promise<MediaItemPayload> {
    const displayName = this.displayNameFromUri(uri);
    const metadata = await this.fetchMetadata(uri);
    const title = this.firstNonEmpty(metadata.title, this.titleWithoutExtension(displayName), uri);
    const durationMs = this.numberFromString(metadata.duration);
    const width = this.numberFromString(metadata.videoWidth);
    const height = this.numberFromString(metadata.videoHeight);
    const facts = this.readFileFacts(uri);
    const item: MediaItemPayload = {
      id: `ohos-${kind}-${uri}`,
      kind: kind,
      title: title,
      artist: kind === 'audio' ? this.firstNonEmpty(metadata.artist, metadata.albumArtist, '未知艺术家') : '未知艺术家',
      album: kind === 'audio' ? this.firstNonEmpty(metadata.album, '未知专辑') : '未知专辑',
      path: uri,
      folder: 'HarmonyOS 用户选择',
      durationMs: durationMs,
      addedAtMs: facts.modifiedAtMs > 0 ? facts.modifiedAtMs : Date.now(),
      sizeBytes: facts.sizeBytes,
      resolution: kind === 'video' && width > 0 && height > 0 ? `${width}x${height}` : '',
      format: this.formatLabel(displayName, metadata.mimeType),
    };
    return item;
  }

  private async fetchMetadata(uri: string): Promise<media.AVMetadata> {
    let fd = -1;
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: fd };
      return await extractor.fetchMetadata();
    } catch (_error) {
      const empty: media.AVMetadata = {};
      return empty;
    } finally {
      if (extractor !== null) {
        try {
          await extractor.release();
        } catch (_error) {
        }
      }
      if (fd >= 0) {
        this.closeFd(fd);
      }
    }
  }

  private readFileFacts(uri: string): FileFacts {
    let fd = -1;
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const stat = fs.statSync(fd);
      return {
        sizeBytes: stat.size,
        modifiedAtMs: this.normalizeEpochMs(stat.mtime),
      };
    } catch (_error) {
      return {
        sizeBytes: 0,
        modifiedAtMs: 0,
      };
    } finally {
      if (fd >= 0) {
        this.closeFd(fd);
      }
    }
  }

  private displayNameFromUri(uri: string): string {
    const withoutQuery = uri.split('?')[0];
    const index = withoutQuery.lastIndexOf('/');
    return index >= 0 ? this.safeDecode(withoutQuery.substring(index + 1)) : this.safeDecode(withoutQuery);
  }

  private safeDecode(value: string): string {
    try {
      return decodeURIComponent(value);
    } catch (_error) {
      return value;
    }
  }

  private titleWithoutExtension(name: string): string {
    const index = name.lastIndexOf('.');
    return index <= 0 ? name : name.substring(0, index);
  }

  private formatLabel(name: string, mimeType?: string): string {
    const extension = this.extensionOf(name);
    if (extension.length > 0) {
      return extension.toUpperCase();
    }
    if (mimeType !== undefined && mimeType.length > 0) {
      const index = mimeType.lastIndexOf('/');
      return index >= 0 ? mimeType.substring(index + 1).toUpperCase() : mimeType.toUpperCase();
    }
    return '';
  }

  private extensionOf(name: string): string {
    const index = name.lastIndexOf('.');
    return index < 0 || index === name.length - 1 ? '' : name.substring(index + 1);
  }

  private firstNonEmpty(...values: Array<string | undefined>): string {
    for (const value of values) {
      if (value !== undefined && value.trim().length > 0) {
        return value.trim();
      }
    }
    return '';
  }

  private numberFromString(value?: string): number {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  private normalizeEpochMs(value: number): number {
    if (value <= 0) {
      return 0;
    }
    return value < 100000000000 ? value * 1000 : value;
  }

  private closeFd(fd: number): void {
    try {
      fs.closeSync(fd);
    } catch (_error) {
    }
  }

  private emptyResult(message: string): ScanResultPayload {
    const result: ScanResultPayload = {
      status: 'completed',
      message: message,
      audioItems: [],
      videoItems: [],
    };
    return result;
  }

  private isPickerCancelled(error: Object): boolean {
    const businessError = error as BusinessError;
    const code = Number(businessError?.code ?? -1);
    return code === 13900012 || code === 1001;
  }

  private errorMessage(error: Object, fallback: string): string {
    if (error instanceof Error && error.message.length > 0) {
      return error.message;
    }
    const businessError = error as BusinessError;
    if (businessError.message !== undefined && businessError.message.length > 0) {
      return businessError.message;
    }
    return fallback;
  }
}
