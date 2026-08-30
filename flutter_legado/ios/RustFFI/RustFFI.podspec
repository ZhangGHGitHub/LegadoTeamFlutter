Pod::Spec.new do |s|
  s.name             = 'RustFFI'
  s.version          = '1.0.1'
  s.summary          = 'Rust FFI 静态库（legado-ffi）iOS 静态链接'
  s.description      = 'liblegado_ffi.a 由 .github/workflows/ios-build.yml 预编译并放置到本目录；' \
                       '通过 -force_load 保证 Dart FFI（DynamicLibrary.process）运行时可查符号。'
  s.homepage         = 'https://github.com/ZhangGHGitHub/LegadoTeamFlutter'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'LegadoTeam' => 'legado@legado.team' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '13.0'
  s.static_framework = true
  s.source_files     = 'RustFFI.h'
  s.public_header_files = 'RustFFI.h'
  s.vendored_libraries = 'libliblegado_ffi.a'
  s.user_target_xcconfig = {
    # Dart FFI 运行时查符号依赖最终二进制包含全部对象：正常链接只抽取被引用对象，
    # 必须 -force_load 全量载入（PROJECT_DIR = ios/ 目录，路径稳定）。
    # DEAD_CODE_STRIPPING 必须关闭：Release 真机构建默认开启 -dead_strip，
    # 会把链接期无引用的 Rust wire 符号裁掉（模拟器 debug 构建不裁剪，
    # 导致"真机 Rust 引擎初始化失败而模拟器正常"——首个 wire 调用报
    # Couldn't resolve native function）。
    'OTHER_LDFLAGS' => '$(inherited) -force_load ${PROJECT_DIR}/RustFFI/libliblegado_ffi.a',
    'DEAD_CODE_STRIPPING' => 'NO'
  }
end
