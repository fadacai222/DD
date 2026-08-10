import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class DdProfileEditField extends StatelessWidget {
  const DdProfileEditField({
    super.key,
    required this.controller,
    this.fieldKey,
    this.label,
    this.hint,
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.maxLength,
    this.minLines = 1,
    this.maxLines = 1,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.counterText,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final Key? fieldKey;
  final String? label;
  final String? hint;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? maxLength;
  final int minLines;
  final int maxLines;
  final bool autocorrect;
  final bool enableSuggestions;
  final String? counterText;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final idleColor = dark ? const Color(0xFF3A3A3A) : const Color(0xFFE2E2E2);
    const focusedColor = DdColors.greenPressed;
    return TextField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      maxLength: maxLength,
      minLines: minLines,
      maxLines: maxLines,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: counterText,
        filled: false,
        isDense: true,
        contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 9),
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: idleColor, width: 0.8),
        ),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: idleColor, width: 0.8),
        ),
        disabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: idleColor, width: 0.6),
        ),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: focusedColor, width: 1.2),
        ),
      ),
    );
  }
}
