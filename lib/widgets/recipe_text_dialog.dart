import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mixlab/models/recipe.dart';

import '../state.dart';
import '../theme.dart';
import 'toast.dart';

/// Shows a recipe as shareable plain text, ready to copy into a post or a
/// message.
///
/// The text is selectable rather than read-only-rendered, so part of it can
/// be taken without the rest, and it is shown in a monospace face because
/// the percentages line up that way.
Future<void> showRecipeTextDialog(
  BuildContext context, {
  required AppState state,
  required Recipe recipe,
}) async {
  final text = state.recipeAsText(recipe);
  final theme = Theme.of(context);

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Share as text'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste this anywhere. MixLab reads the same format back, so '
              'it can be imported here or on another install.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            Gap.vMd,
            Flexible(
              child: SingleChildScrollView(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            Navigator.pop(context);
            showToast(context, 'Recipe copied to the clipboard.');
          },
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('Copy'),
        ),
      ],
    ),
  );
}
