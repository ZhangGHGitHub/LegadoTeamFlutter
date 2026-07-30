import re

with open('legado-db/src/schema.rs', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace SCHEMA_VERSION from 95 to 96
content = re.sub(r'pub const SCHEMA_VERSION: u32 = 95;', 'pub const SCHEMA_VERSION: u32 = 96;', content)

with open('legado-db/src/schema.rs', 'w', encoding='utf-8') as f:
    f.write(content)

print('Updated SCHEMA_VERSION to 96')
