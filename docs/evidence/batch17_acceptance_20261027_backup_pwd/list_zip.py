import glob
import zipfile


def main() -> None:
    for path in sorted(glob.glob("packages/*.zip")):
        print(path)
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                print("   ", info.filename, info.file_size)


if __name__ == "__main__":
    main()
