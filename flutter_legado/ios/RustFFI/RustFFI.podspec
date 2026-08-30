Pod::Spec.new do |s|
  s.name             = 'RustFFI'
  s.version          = '1.0.3'
  s.summary          = 'Rust FFI 静态库（legado-ffi）iOS 静态链接'
  s.description      = 'liblegado_ffi.a 由 .github/workflows/ios-build.yml 预编译并放置到本目录；' \
                       '通过 -force_load 保证 Dart FFI（DynamicLibrary.process）运行时可查 FRB PDE 分发器符号。'
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
    # 注意：不可加 -Wl,-exported_symbols_list——FRB 2.11 的 PDE 分发器符号
    # （frb_pde_ffi_dispatcher_primary 等）以下划线之外的名字导出，白名单会误杀。
    'OTHER_LDFLAGS' => '$(inherited) -force_load ${PROJECT_DIR}/RustFFI/libliblegado_ffi.a',
    # 三项协同防止符号被"无声裁掉"导致真机 Rust 初始化失败：
    # 1) 链接期死代码裁剪（会裁掉链接期无引用的 wire 符号）
    'DEAD_CODE_STRIPPING' => 'NO',
    # 2) 链接后安装期 strip：Release 默认 STRIP_INSTALLED_PRODUCT=YES 且
    #    默认样式连全局符号一并剥离——dlsym 运行时查不到（模拟器 debug
    #    构建无此阶段，即"真机失败而模拟器正常"的根因）
    'STRIP_INSTALLED_PRODUCT' => 'NO',
    'STRIP_STYLE' => 'non-global'
  }
end
