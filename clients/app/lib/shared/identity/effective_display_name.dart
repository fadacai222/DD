String effectiveDisplayName({
  required String displayName,
  required String handle,
  String remark = '',
}) {
  final privateRemark = remark.trim();
  if (privateRemark.isNotEmpty) return privateRemark;

  final resolvedDisplayName = displayName.trim();
  if (resolvedDisplayName.isNotEmpty) return resolvedDisplayName;

  return handle.trim();
}
