
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import LumioAppStoragePlugin from '../plugins/LumioAppStoragePlugin';
import LumioMediaLibraryPlugin from '../plugins/LumioMediaLibraryPlugin';
import LumioPlaybackPlugin from '../plugins/LumioPlaybackPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    this.addPlugin(new LumioAppStoragePlugin())
    this.addPlugin(new LumioMediaLibraryPlugin())
    this.addPlugin(new LumioPlaybackPlugin())
  }
}
