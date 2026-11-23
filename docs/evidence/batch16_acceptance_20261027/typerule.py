import subprocess, time
ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
S = "192.168.100.62:5555"
def sh(*a):
    return subprocess.run([ADB, "-s", S] + list(a), capture_output=True).stdout.decode("utf-8","replace")
# 聚焦 uploadUrl 字段并全选
sh("shell", "input", "tap", "540", "528"); time.sleep(0.8)
sh("shell", "input", "swipe", "540", "528", "540", "528", "900"); time.sleep(1.5)
sh("shell", "input", "tap", "789", "724")  # Select all（工具条位置由 dump 确认）
time.sleep(0.6)
for seg in ['http://127.0.0.1:18080/upload,{', '"', 'body:{', '"', 'file:', '"', 'fileRequest', '"', '}}']:
    if seg == '"':
        sh("shell", "input", "keycombination", "59", "75")
    else:
        sh("shell", "input", "text", seg)
    time.sleep(0.15)
print(sh("shell", "uiautomator dump /data/local/tmp/ui.xml"))
