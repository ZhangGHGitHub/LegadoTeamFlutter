---
kind: dependency_management
name: 多语言工程依赖管理：Gradle Version Catalog、Flutter Pub、Rust Cargo Workspace 与 Dependabot
category: dependency_management
scope:
    - '**'
source_files:
    - gradle/libs.versions.toml
    - app/build.gradle
    - app/download.gradle
    - flutter_legado/pubspec.yaml
    - rust/Cargo.toml
    - modules/web/package.json
    - .github/dependabot.yml
---

Legado 是一个跨多语言（Android Kotlin/Java、Flutter/Dart、Rust、Vue.js）的聚合根工程，依赖管理采用各语言生态的标准工具，并通过集中式版本目录和自动化更新机制统一治理。