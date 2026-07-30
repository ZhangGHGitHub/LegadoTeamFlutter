use legado_db::Database;

fn main() {
    let db_path = "d:/OH-WorkSpace/LegadoTeam/legado/flutter_legado/build/windows/x64/runner/Release/legado.db";
    
    println!("Opening database at: {}", db_path);
    match Database::open(db_path) {
        Ok(db) => {
            println!("Database opened successfully");
            match db.get_version() {
                Ok(version) => println!("Database version: {}", version),
                Err(e) => println!("Failed to get version: {:?}", e),
            }
        }
        Err(e) => {
            println!("Failed to open database: {:?}", e);
        }
    }
}
