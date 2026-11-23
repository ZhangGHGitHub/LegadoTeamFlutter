import sys
import xml.etree.ElementTree as ET


def main() -> None:
    path = sys.argv[1]
    tree = ET.parse(path)
    root = tree.getroot()
    for node in root.iter("node"):
        text = (node.get("text") or "").strip()
        desc = (node.get("content-desc") or "").strip()
        cls = (node.get("class") or "").split(".")[-1]
        bounds = node.get("bounds") or ""
        flags = []
        if node.get("clickable") == "true":
            flags.append("click")
        if node.get("long-clickable") == "true":
            flags.append("long")
        if node.get("scrollable") == "true":
            flags.append("scroll")
        if node.get("password") == "true":
            flags.append("PWD")
        if node.get("focused") == "true":
            flags.append("focus")
        if not text and not desc:
            continue
        payload = text if text else desc
        print(f"{cls:16s} {' '.join(flags):12s} {bounds:24s} {payload}")
    print("--- nodes:", sum(1 for _ in root.iter("node")))


if __name__ == "__main__":
    main()
