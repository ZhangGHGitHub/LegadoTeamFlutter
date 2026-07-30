import sys

with open('migrations.rs', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find the line with "// rssSources 表新增列" and add table_exists check
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    
    if '// rssSources 表新增列' in line and '仅当表存在时' not in line:
        # Add the comment modification
        new_lines.append(line.replace('// rssSources 表新增列', '// rssSources 表新增列（仅当表存在时）'))
        i += 1
        
        # Add the if table_exists check
        new_lines.append('        if table_exists(conn, "rssSources")? {\n')
        
        # Process all rssSources add_column_if_not_exists calls
        while i < len(lines) and 'add_column_if_not_exists(conn, "rssSources"' in lines[i]:
            # Indent these lines one more level
            new_lines.append('    ' + lines[i])
            i += 1
        
        # Close the if block
        new_lines.append('        }\n')
    else:
        new_lines.append(line)
        i += 1

with open('migrations.rs', 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print("Updated migrations.rs successfully")
