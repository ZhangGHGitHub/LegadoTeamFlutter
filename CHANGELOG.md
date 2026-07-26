# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Multi-Agent parallel development scheme (5 roles: Rust-Core/Rust-Infra/Flutter-UI/Integration/QA)
- Module ownership matrix and branch protocol (`feature/{agent}-{task}`)
- Daily sync rhythm (08:00 cutoff) and quality gates
- legado-core: download_manager module, read_state chapter preloading
- legado-server: download handler + route expansion

### Changed
- Agent configs specialized with role-specific prompts and responsibility zones
- rust-ci.yml: exclude legado-ffi from workspace checks (requires Flutter toolchain)
- flutter-ci.yml: pin Flutter 3.41.7, add test step
- All workflows: upgrade actions/checkout to v7 (Node.js 24 compat)

### Fixed
- Rust CI failure (exit 101): legado-ffi needs Flutter/Dart toolchain not available in Rust CI
- Flutter CI failure (exit 1): unspecified Flutter version didn't satisfy `sdk: ^3.11.5`
- Node.js 20 deprecation warnings in GitHub Actions

## [2.0.0] - 2026-07-26

### Added
- **Rust Core Engine**: Complete Rust workspace with 8 crates (core, parser, net, js, book, db, ffi, server)
- **Flutter UI**: 18 screens, 12 providers, cross-platform Material3 design
- **QuickJS Engine**: Real QuickJS runtime with 70+ host APIs, sandbox security, engine pooling
- **Rule Parser**: RuleAnalyzer with JSoup/XPath/JsonPath/Regex parsers + @js: mode
- **Network Layer**: LegadoClient with retry/rate-limit/proxy/UA rotation/SSL middleware
- **Book Parsers**: EPUB/TXT/MOBI/PDF/UMD format support + TXT/EPUB/HTML export
- **Database**: SQLite Schema v95, Room migration (v90-v95), 7 repositories
- **HTTP Server**: axum-based REST API with 25+ endpoints + Web SPA frontend
- **FFI Bridge**: flutter_rust_bridge v2.12.0 with 30+ export functions
- **Multimedia**: Audio playback with preload optimization, TTS integration
- **Reading Engine**: Chapter preloading state machine with LRU cache and failure circuit breaker
- **Security**: File API sandbox with path traversal protection
- **Cloud Sync**: WebDAV client for book data synchronization
- **i18n**: Chinese/English dual language support
- **CI/CD**: GitHub Actions workflows for Rust and Flutter
- **Build Scripts**: Windows one-click build (PowerShell + BAT)

### Changed
- Migrated from Android Kotlin to Rust core + Flutter UI architecture
- Network stack unified from ureq to LegadoClient (connection pooling, middleware chain)
- JS engine upgraded from stub to real QuickJS runtime with engine pooling

### Fixed
- QuickJS timeout interrupt (was using relative time instead of absolute deadline)
- Java namespace for book source JS scripts (java.xxx() calling convention)
- File API path traversal vulnerability (added sandbox validation)
- HostApiRegistry dead code removed (150 lines of empty TODOs)

## [1.0.0] - Legacy

### Description
- Original Android Kotlin implementation (io.legado.app)
- 329 releases tracked via git tags (3.YYMMDDHH format)
- Full-featured Android reading app with 60+ Kotlin models, 20+ services
