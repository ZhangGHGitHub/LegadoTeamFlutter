use std::io::Cursor;
use sevenz_rust2::{ArchiveEntry, ArchiveWriter};

fn main() {
    let out = std::env::args().nth(1).expect("output path");
    let mut w = ArchiveWriter::create(&out).expect("create");
    let data = b"EVIL-PAYLOAD\n";
    let mut entry = ArchiveEntry::new_file("../evil.txt");
    entry.size = data.len() as u64;
    w.push_archive_entry(entry, Some(Cursor::new(data.to_vec())))
        .expect("push evil");
    let ok = "正常文本内容 normal txt\n".as_bytes();
    let mut entry2 = ArchiveEntry::new_file("normal.txt");
    entry2.size = ok.len() as u64;
    w.push_archive_entry(entry2, Some(Cursor::new(ok.to_vec())))
        .expect("push normal");
    w.finish().expect("finish");
    println!("written {out}");
}
