import 'package:flutter/material.dart';

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
    this.underline = false,
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
  final bool underline;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabledBorder = underline
        ? UnderlineInputBorder(
            borderSide: BorderSide(color: scheme.outlineVariant, width: 0.8),
          )
        : null;
    final focusedBorder = underline
        ? UnderlineInputBorder(
            borderSide: BorderSide(color: scheme.outline, width: 1),
          )
        : null;

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
        filled: underline ? false : null,
        border: enabledBorder,
        enabledBorder: enabledBorder,
        disabledBorder: enabledBorder,
        focusedBorder: focusedBorder,
      ),
    );
  }
}
