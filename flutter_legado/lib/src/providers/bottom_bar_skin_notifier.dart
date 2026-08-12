import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../services/bottom_bar_skin_service.dart';

/// 底栏皮肤状态
class BottomBarSkinState {
  const BottomBarSkinState({
    this.skins = const [],
    this.active = '',
    this.loading = false,
    this.error,
  });

  final List<String> skins;
  final String active;
  final bool loading;
  final String? error;

  BottomBarSkinState copyWith({
    List<String>? skins,
    String? active,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return BottomBarSkinState(
      skins: skins ?? this.skins,
      active: active ?? this.active,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class BottomBarSkinNotifier extends Notifier<BottomBarSkinState> {
  final _service = BottomBarSkinService.instance;

  @override
  BottomBarSkinState build() {
    Future.microtask(reload);
    return const BottomBarSkinState(loading: true);
  }

  Future<void> reload() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final skins = await _service.list();
      final active = await _service.getActive();
      state = BottomBarSkinState(skins: skins, active: active);
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> setActive(String name) async {
    await _service.setActive(name);
    final active = name.isEmpty ? '' : name;
    state = state.copyWith(active: active);
  }

  Future<bool> delete(String name) async {
    final ok = await _service.delete(name);
    if (ok) await reload();
    return ok;
  }

  Future<String> importZipFile(File zipFile, {String? preferredName}) async {
    final name = await _service.importZip(zipFile, preferredName: preferredName);
    await reload();
    await setActive(name);
    return name;
  }
}

final bottomBarSkinProvider =
    NotifierProvider<BottomBarSkinNotifier, BottomBarSkinState>(
  BottomBarSkinNotifier.new,
);
