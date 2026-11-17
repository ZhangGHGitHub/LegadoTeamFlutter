import 'package:flutter/material.dart';

/// 书源信息卡片 — 含开关
class SourceCard extends StatelessWidget {
  final String name;
  final String url;
  final bool isEnabled;
  final String? group;
  final VoidCallback? onTap;
  final VoidCallback? onToggle;

  const SourceCard({
    super.key,
    required this.name,
    required this.url,
    this.isEnabled = true,
    this.group,
    this.onTap,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: isEnabled
                                ? colorScheme.onSurface
                                : colorScheme.onSurfaceVariant,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      url,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (group != null) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          group!,
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onTertiaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: isEnabled,
                onChanged: onToggle != null ? (_) => onToggle!() : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
