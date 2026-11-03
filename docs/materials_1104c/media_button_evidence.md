# 批9b-5 耳机媒体键设备验收 — 关键日志片段（2026-11-04）

设备端点：192.168.100.62:5555（MuMu「Test测试」，Android 15，1080x1920/480dpi）
应用：io.legado.flutter_legado 2.0.449（versionCode 450）
APK sha256：b1c68408ddf98e1b7800e94f70a1dcb33d57fb18a1026f9a55180c398799e0cf

## 1. 静态接收器注册（dumpsys package / aapt2 dump xmltree）

```
android.intent.action.MEDIA_BUTTON:
  eb2669a io.legado.flutter_legado/io.legado.flutter.MediaButtonReceiver filter 254cbcb
    Action: "android.intent.action.MEDIA_BUTTON"
```

APK manifest（aapt2 dump xmltree app-release.apk）：

```
E: receiver (line=406)
  A: android:name="io.legado.flutter.MediaButtonReceiver"
  A: android:exported=true
  E: intent-filter (line=409)
    E: action
      A: android:name="android.intent.action.MEDIA_BUTTON"
```

会话活跃时系统登记的媒体键接收器（dumpsys media_session）：

```
mediaButtonReceiver=MBR {pi=PendingIntent{... io.legado.flutter_legado broadcastIntent}},
  componentName=ComponentInfo{io.legado.flutter_legado/io.legado.flutter.MediaButtonReceiver}
```

## 2. 设置持久化（/data/data/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml）

杀进程重启后：

```
<boolean name="flutter.readAloudByMediaButton" value="true" />
<boolean name="flutter.mediaButtonOnExit" value="true" />
```

## 3. 前台阅读（无播放会话）

readAloudByMediaButton=true：

```
D/MediaButtonReceiver(45017): 转发耳机键到 Flutter（keyCode=85）
I/flutter (45017): （朗读启动，界面提示）未配置可用朗读引擎，将按估算节奏朗读
```

87/88（无会话）：

```
D/MediaButtonReceiver(45943): 转发耳机键到 Flutter（keyCode=87）
I/flutter (45943): [耳机按键] 无播放会话，忽略上一首/下一首键
D/MediaButtonReceiver(45943): 转发耳机键到 Flutter（keyCode=88）
I/flutter (45943): [耳机按键] 无播放会话，忽略上一首/下一首键
```

readAloudByMediaButton=false（85/87/88）：

```
D/MediaButtonReceiver(46732): 转发耳机键到 Flutter（keyCode=85）
I/flutter (46732): [耳机按键] 未开启「耳机按键启动朗读」，且当前无播放，忽略
D/MediaButtonReceiver(46732): 转发耳机键到 Flutter（keyCode=87）
I/flutter (46732): [耳机按键] 无播放会话，忽略上一首/下一首键
D/MediaButtonReceiver(46732): 转发耳机键到 Flutter（keyCode=88）
I/flutter (46732): [耳机按键] 无播放会话，忽略上一首/下一首键
```

## 4. 后台（无播放会话）

readAloud=true、mediaButtonOnExit=false：

```
D/MediaButtonReceiver(45943): 转发耳机键到 Flutter（keyCode=85）
I/flutter (45943): [耳机按键] 已退出且未开启「全程响应耳机按键」，忽略
```

readAloud=true、mediaButtonOnExit=true（本地导入书 type=4096 缺 text 位）：

```
D/MediaButtonReceiver(45943): 转发耳机键到 Flutter（keyCode=85）
I/flutter (45943): [耳机按键] 书架无最近阅读的文本，忽略启动朗读
```

同场景，临时将测试书 type 补为 4104（text|local）后：

```
D/MediaButtonReceiver(47425): 转发耳机键到 Flutter（keyCode=85）
I/flutter (47425): [耳机按键] 从最近阅读启动朗读：qa_9b5_book
D/MediaSessionService(837): onSessionPlaybackStateChanged: ... playbackState=PLAYING(3)
I/ActivityManager(837): Background started FGS: Allowed [... PlaybackForegroundService ... code:ACTIVITY_VISIBILITY_GRACE_PERIOD]
W/ActivityManager(837): Foreground service started from background can not have location/camera/microphone access: ...PlaybackForegroundService
```

前台 shelf（readAloud=false，mediaButtonOnExit=false）：

```
D/MediaButtonReceiver(46732): 转发耳机键到 Flutter（keyCode=85）
I/flutter (46732): [耳机按键] 未开启「耳机按键启动朗读」，且当前无播放，忽略
```

## 5. 阅读器退出后 / 陈旧会话

停止朗读后会话仍 active（无音频时系统不路由按键）：

```
D/MediaButtonReceiver(45943): 媒体会话活跃，交会话处理（keyCode=85）
```

dumpsys media_session：

```
legado_flutter_media io.legado.flutter_legado/legado_flutter_media/4
  active=true
  state=PlaybackState {state=IDLE...}（停止后）
```

## 6. 进程被杀

force-stop 后（app 处于 stopped 状态，系统不投递）：

```
pidof io.legado.flutter_legado -> 空
topResumedActivity=com.microsoft.launcher/.Launcher
```

`am kill`（进程被杀但未 stopped）后注入：

```
I/ActivityManager(837): Start proc 45943:io.legado.flutter_legado/u0a66 for broadcast {io.legado.flutter_legado/io.legado.flutter.MediaButtonReceiver}
D/MediaButtonReceiver(45943): 转发耳机键到 Flutter（keyCode=85）
D/HeadsetMediaButton(45943): 收到耳机键但 Flutter 引擎未就绪，忽略（keyCode=85）
```

## 7. 通知 / 前台服务

朗读回退会话运行中：

```
isForeground=true foregroundId=7776 types=0x00000002
NotificationRecord(... pkg=io.legado.flutter_legado ... id=7776 ... channel=legado_playback_foreground)
```

停止朗读后：NotificationRecord 0 条、PlaybackForegroundService 0 个；force-stop 后同样清零。

## 8. 快速连按 5×85（间隔 150ms）

```
04:50:58.031 转发 keyCode=85 → 未开启「耳机按键启动朗读」…忽略
04:50:58.182 转发 keyCode=85 → [耳机按键] 去抖窗口内重复事件，忽略（HeadsetMediaKey.toggle）
04:50:58.333 转发 keyCode=85 → 未开启「耳机按键启动朗读」…忽略
04:50:58.483 转发 keyCode=85 → [耳机按键] 去抖窗口内重复事件，忽略（HeadsetMediaKey.toggle）
04:50:58.634 转发 keyCode=85 → 未开启「耳机按键启动朗读」…忽略
```

无 FATAL、无会话残留（media_session legado 计数 0，PlaybackForegroundService 0）。

## 10. TTS / 媒体会话（BLOCKED 依据）

```
settings get secure tts_default_synth -> null
pm list packages | grep -i tts -> （空）
dumpsys media_session: Media button session is null
```

朗读界面提示：未配置可用朗读引擎，将按估算节奏朗读（无实际音频）。
