#!/usr/bin/env bash
# Rhino String-parameter coercion probe: compile + run against the original engine JAR.
#
# Usage (from the repository root):
#   bash docs/materials_rhino_probe_20261006/run_probe.sh
#
# The JDK 17 bin directory can be overridden:
#   JAVA_BIN=/path/to/jdk-17/bin bash docs/materials_rhino_probe_20261006/run_probe.sh
#
# Output goes to stdout; the recorded evidence is
# docs/materials_rhino_probe_20261006/probe_output.txt
# (produced with: bash docs/materials_rhino_probe_20261006/run_probe.sh > docs/materials_rhino_probe_20261006/probe_output.txt 2>&1)
set -euo pipefail

JAVA_BIN="${JAVA_BIN:-/c/Program Files/Eclipse Adoptium/jdk-17.0.19.10-hotspot/bin}"
JAR="third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/htmlunit-core-js-5.3.0-legado.4.jar"
DIR="docs/materials_rhino_probe_20261006"

"$JAVA_BIN/javac" -encoding UTF-8 -cp "$JAR" -d "$DIR/_classes" "$DIR/RhinoStringParamProbe.java"
"$JAVA_BIN/java" -cp "$DIR/_classes;$JAR" RhinoStringParamProbe
rm -rf "$DIR/_classes"
