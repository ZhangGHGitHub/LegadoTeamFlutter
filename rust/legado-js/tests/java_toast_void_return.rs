//! java.toast / java.longToast 返回值端到端测试（quickjs 档）
//!
//! 定性结论（2026-09-26，语料 🔞🎨天脉漫画 tnmm.cc / 📂大美书网
//! dameishuwang.net 实测报错 `Network error: Request failed: builder error`
//! ——裸 builder error = URL 不可解析）：
//! 书源 searchUrl 选项常带 `"js": "java.toast('正在搜索…');"`（纯 UX 提示）。
//! 上游 Kotlin toast 返回 Unit→JS null，`evalJS(...)?.toString()?.let { url = it }`
//! 不改写 URL；我方桥 toast 曾**原样返回消息文本** → 返回值非空 → URL 被
//! 改写成提示文案 → Url::parse 失败 → 裸 builder error。
//!
//! 修复：toast/longToast 返回空串（对齐上游 void→null 语义，URL 选项
//! js 的空返回由 analyze_url 守卫跳过改写）。本测试钉死该返回值契约。

#![cfg(feature = "quickjs")]

use legado_js::engine::JsEngine;
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

/// 绿态：toast / longToast 返回空串（上游 void→null 语义），
/// 且 UI 动作仍入队（提示可见性不受返回值修复影响）。
#[test]
fn java_toast_and_long_toast_return_empty_like_upstream_void() {
    let engine = production_engine();
    let out: String = JsEngine::eval(&engine, "java.toast('正在搜索漫画，请稍等…')")
        .expect("java.toast 调用失败");
    assert_eq!(out, "", "toast 应返回空串（上游 Unit→null）；观测: {out}");
    let out2: String = JsEngine::eval(&engine, "java.longToast('正在搜索中，请稍等！')")
        .expect("java.longToast 调用失败");
    assert_eq!(out2, "", "longToast 应返回空串；观测: {out2}");
    // 拼接场景（规则里 toast 后续接 URL 构造）不受影响
    let out3: String = JsEngine::eval(
        &engine,
        "java.toast('提示'); 'https://origin.test/api/search'",
    )
    .expect("toast + 表达式求值失败");
    assert_eq!(out3, "https://origin.test/api/search");
}
