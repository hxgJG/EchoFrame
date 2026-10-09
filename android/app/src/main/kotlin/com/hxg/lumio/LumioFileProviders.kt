package com.hxg.lumio

import androidx.core.content.FileProvider

// Android 按组件类名缓存本地 Provider；不同 authority 必须使用不同组件类。
class LumioReceivedFileProvider : FileProvider()

class LumioUpdateFileProvider : FileProvider()
