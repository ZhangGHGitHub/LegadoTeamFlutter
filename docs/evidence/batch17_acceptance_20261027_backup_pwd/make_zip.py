import sys
import zipfile


def main() -> None:
    out = sys.argv[1]
    specs = sys.argv[2:]
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for spec in specs:
            src, dest = spec.split(":", 1)
            zf.write(src, dest)


if __name__ == "__main__":
    main()
