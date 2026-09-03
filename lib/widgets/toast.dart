import 'package:flutter/material.dart';

import '../models.dart';

/// Shows a snackbar, replacing any that is already visible so rapid actions
/// do not queue up behind each other.
///
/// Plain confirmations use [toastShort]; anything with an [action] uses
/// [toastUndo] so there is time to click it.
void showToast(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  bool isError = false,
}) {
  final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: action != null ? toastUndo : toastShort,
      behavior: SnackBarBehavior.floating,
      width: 460,
      action: action,
      backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
    ),
  );
}
