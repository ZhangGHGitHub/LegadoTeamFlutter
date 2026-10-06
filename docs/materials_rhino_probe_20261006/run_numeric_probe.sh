#!/usr/bin/env bash
# Rhino 数值/布尔形参 + java.ajax(Object) 边界探针：编译 + 用原版引擎 JAR 运行。
#
# 用法（仓库根目录）：
#   bash docs/materials_rhino_probe_20261006/run_numeric_probe.sh
#
# JDK 17 bin 目录可覆盖：
#   JAVA_BIN=/path/to/jdk-17/bin bash docs/materials_rhino_probe_20261006/run_numeric_probe.sh
#
# 输出到 stdout；入库证据为
# docs/materials_rhino_probe_20261006/probe_numeric_output.txt
# （产生方式：bash docs/materials_rhino_probe_20261006/run_numeric_probe.sh > docs/materials_rhino_probe_20261006/probe_numeric_output.txt 2>&1）
set -euo pipefail

JAVA_BIN="${JAVA_BIN:-/c/Program Files/Eclipse Adoptium/jdk-17.0.19.10-hotspot/bin}"
JAR="third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/htmlunit-core-js-5.3.0-legado.4.jar"
DIR="docs/materials_rhino_probe_20261006"

"$JAVA_BIN/javac" -encoding UTF-8 -cp "$JAR" -d "$DIR/_classes" "$DIR/RhinoNumericParamProbe.java"
"$JAVA_BIN/java" -cp "$DIR/_classes;$JAR" RhinoNumericParamProbe
rm -rf "$DIR/_classes"
