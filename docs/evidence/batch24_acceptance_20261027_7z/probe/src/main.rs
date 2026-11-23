use std::io::Read;
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let archive = &args[1];
    println!("== {archive}");
    println!("list -> {:?}", legado_book::archive::list_7z_book_files(archive));
    let mut reader = sevenz_rust2::ArchiveReader::open(archive, sevenz_rust2::Password::empty()).unwrap();
    let a = reader.archive();
    for (i, f) in a.files.iter().enumerate() {
        println!("file[{i}] name={:?} dir={} stream={} size={}", f.name, f.is_directory, f.has_stream, f.size);
    }
    let mut calls = 0;
    let _ = reader.for_each_entries(|entry, stream| {
        calls += 1;
        let mut buf = [0u8; 4096];
        loop { match stream.read(&mut buf) { Ok(0) => break, Ok(_) => {}, Err(e) => return Err(sevenz_rust2::Error::from(e)) } }
        println!("callback[{calls}] {:?}", entry.name);
        Ok(true)
    });
    let out = std::env::temp_dir().join("probe_iter_out");
    let _ = std::fs::remove_dir_all(&out);
    println!("import -> {:?}", legado_book::archive::import_7z_file(archive, out.to_str().unwrap()));
}
