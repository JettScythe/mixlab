import 'package:flutter/material.dart';

/// Five-star rating. Tapping the current value clears it.
class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.value,
    this.onChanged,
    this.size = 22,
  });

  final int? value;
  final ValueChanged<int?>? onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = theme.colorScheme.tertiary;
    final inactive = theme.colorScheme.outlineVariant;
    final readOnly = onChanged == null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.symmetric(horizontal: size * 0.08),
            constraints: const BoxConstraints(),
            iconSize: size,
            tooltip: readOnly
                ? null
                : (value == i ? 'Clear rating' : '$i star${i == 1 ? '' : 's'}'),
            onPressed: readOnly
                ? null
                : () => onChanged!(value == i ? null : i),
            icon: Icon(
              (value ?? 0) >= i ? Icons.star : Icons.star_border,
              color: (value ?? 0) >= i ? active : inactive,
            ),
          ),
      ],
    );
  }
}

/// Compact non-interactive display, e.g. "4.5 ★" on a recipe card.
class StarSummary extends StatelessWidget {
  const StarSummary({super.key, required this.average, this.count});

  final double average;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star, size: 15, color: theme.colorScheme.tertiary),
        const SizedBox(width: 2),
        Text(
          average.toStringAsFixed(1) + (count != null ? ' ($count)' : ''),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
