import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';

// [SB-HUNT | 2026-09-25] 换源流程统一入口（阅读器两个换源入口共用）：
// 菜单面板 _changeSourceFlow / 顶栏 _changeBookSource 原为两份同形拷贝，
// 各自推换源页、各自挂 10min「正在更换书源…」条、各自跑整书重载——真机
// 缺陷「换源后出现第二条/残留 SnackBar」（证据
// docs/parity_shots/verify_ui_20260922/swb_* 序列）：
//   ① 双入口无共享重入守卫：在途期间第二入口再开一个换源页、再挂一条
//      进行中条；removeCurrentSnackBar() 只收队首，后挂的条在结果条
//      收走队首后重新浮出 → 残留；
//   ② 离场竞态：重载 await 期间用户退出阅读器，`!context.mounted` 提前
//      返回跳过清理，10min 进行中条挂在 root messenger 上残留；
//   ③ 结果重复：换源页已弹「已切换到「源名」」，阅读器侧又弹
//      「已更换书源：源名」；且快路径（<4s）下 removeCurrentSnackBar()
//      收掉的是队首的页侧「已切换到」条（先入队），进行中条反而残留。
//
// 统一修法（本文件 + ReaderNotifier._changeSourceFlowActive 锁）：
// - 共享重入锁：ReaderNotifier.tryBeginChangeSourceFlow/endChangeSourceFlow
//   （provider/notifier 级，两入口共用）。在途（导航或重载任一阶段）期间
//   第二次触发静默忽略——进行中条本身就是轻提示，不再堆叠第二条、不再
//   开第二个换源页（否则还会再弹一次页侧「已切换到」）；
// - 进行中条 10min 保留，语义重估：清理既有保证后它退化为「挂起保险」
//   （重载卡死 10min 才自动消失，正常路径必被 clearSnackBars 收起）；
// - 必收：重载完成（成功/失败/异常，reload 不抛异常）后无条件
//   messenger.clearSnackBars()——root messenger 队列跨离场有效、空队列
//   安全、不踩 scaffold.dart:341 断言（[P2-9 fix2] close() 断言的替代
//   原语），任何情况（双入口/异常/取消/离场）不留残留；
// - 结果去重：成功反馈只保留换源页「已切换到「源名」」（全仓 5 个
//   AppRoutes.changeSource 调用方中 3 个——朗读页/详情页/阅读页
//   ErrorView 换源——仅依赖该条成功反馈，删页侧条会令其静默），阅读器
//   侧只保留失败条「更换书源后重载失败：…」。代价：快路径（<4s）成功
//   时 clearSnackBars 会连带清掉仍在展示的页侧「已切换到」条——用户
//   停留在原阅读器且状态已重载，属可接受的静默（无残留为硬要求）。
//
// [P2-9 fix | 2026-09-24] 生产 /change_source 路由是
// _ChangeSourceSheetRoute（PageRouteBuilder<dynamic>，见
// AppRoutes.generateRoute）：类型化 pushNamed<String> 会在运行期把
// 生成的路由强转 Route<String?> 抛 TypeError（真机崩溃）。对齐
// 详情页 Task#24 既有修法（book_info_screen_builders
// ._showChangeSourceDialog）：无类型 pushNamed + result is String 判定。
Future<void> runChangeSourceFlow(
  WidgetRef ref,
  BuildContext context,
  Book book,
) async {
  final notifier = ref.read(readerNotifierProvider.notifier);
  // [SB-HUNT] 共享重入守卫：在途 → 静默忽略（轻提示 = 已在展示的进行中条）
  if (!notifier.tryBeginChangeSourceFlow()) return;
  final messenger = ScaffoldMessenger.of(context);
  final result = await Navigator.pushNamed(
    context,
    AppRoutes.changeSource,
    arguments: book,
  );
  // 导航阶段锁释放：同步交接给重载阶段锁（reloadAfterSourceChange 入口
  // 置位 + finally 复位），中间无 await、无用户输入窗口
  notifier.endChangeSourceFlow();
  if (result is! String) return; // 取消 / 关闭 pop null → 不做任何事
  if (!context.mounted) return; // 离场：不展示进行中条、不发起重载
  messenger.showSnackBar(
    const SnackBar(
      content: Text('正在更换书源…'),
      duration: Duration(minutes: 10), // 挂起保险（见文件头语义重估）
    ),
  );
  final err = await notifier.reloadAfterSourceChange(result); // 不抛异常
  // [SB-HUNT] 必收：先清理（离场/异常也收），再视是否仍在场展示结果条
  messenger.clearSnackBars();
  if (!context.mounted) return; // 结果条仅在阅读器仍在场时展示
  if (err != null) {
    messenger.showSnackBar(SnackBar(content: Text('更换书源后重载失败：$err')));
  }
  // 成功不弹阅读器侧结果条（去重：换源页「已切换到」为唯一成功反馈）
}
