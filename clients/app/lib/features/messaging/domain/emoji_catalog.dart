enum EmojiCategoryKey {
  smileysPeople,
  animalsNature,
  foodDrink,
  activity,
  travelPlaces,
  objects,
  symbols,
  flags,
}

final class EmojiCategoryData {
  const EmojiCategoryData({
    required this.key,
    required this.label,
    required this.icon,
    required this.items,
  });

  final EmojiCategoryKey key;
  final String label;
  final String icon;
  final List<String> items;
}

final class EmojiCatalog {
  EmojiCatalog._();

  static final List<EmojiCategoryData> categories = <EmojiCategoryData>[
    EmojiCategoryData(
      key: EmojiCategoryKey.smileysPeople,
      label: '表情与人物',
      icon: '😀',
      items: _dedupe(<String>[
        ..._ranges(const <(int, int)>[
          (0x1F600, 0x1F64F),
          (0x1F910, 0x1F92F),
          (0x1F970, 0x1F97A),
          (0x1FAE0, 0x1FAE8),
          (0x1F440, 0x1F450),
          (0x1F466, 0x1F487),
          (0x1F590, 0x1F596),
          (0x1F918, 0x1F91F),
          (0x1F9D0, 0x1F9DD),
        ]),
        ..._skinToneVariants(const <String>[
          '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞',
          '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️',
          '🫵', '👍', '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '🫶',
          '👐', '🤲', '🤝', '🙏', '✍️', '💅', '🤳', '💪', '🦵', '🦶',
        ]),
        ..._professionSequences(),
        ..._familySequences,
      ]),
    ),
    EmojiCategoryData(
      key: EmojiCategoryKey.animalsNature,
      label: '动物与自然',
      icon: '🐻',
      items: _dedupe(_ranges(const <(int, int)>[
        (0x1F330, 0x1F343),
        (0x1F400, 0x1F43E),
        (0x1F980, 0x1F9AE),
        (0x1FAB0, 0x1FABD),
      ])),
    ),
    EmojiCategoryData(
      key: EmojiCategoryKey.foodDrink,
      label: '食物与饮品',
      icon: '🍜',
      items: _dedupe(_ranges(const <(int, int)>[
        (0x1F345, 0x1F37F),
        (0x1F950, 0x1F96F),
        (0x1F9C0, 0x1F9CA),
        (0x1FAD0, 0x1FAD9),
      ])),
    ),
    EmojiCategoryData(
      key: EmojiCategoryKey.activity,
      label: '活动',
      icon: '⚽',
      items: _dedupe(<String>[
        ..._ranges(const <(int, int)>[
          (0x1F3A0, 0x1F3C4),
          (0x1F3C6, 0x1F3CA),
          (0x1F3CF, 0x1F3D3),
          (0x1F93C, 0x1F945),
          (0x1F947, 0x1F94C),
        ]),
        ..._symbols(const <int>[
          0x26BD,
          0x26BE,
          0x26F3,
          0x26F8,
          0x26F9,
        ]),
      ]),
    ),
    EmojiCategoryData(
      key: EmojiCategoryKey.travelPlaces,
      label: '旅行与地点',
      icon: '✈️',
      items: _dedupe(<String>[
        ..._ranges(const <(int, int)>[
          (0x1F680, 0x1F6C5),
          (0x1F6CB, 0x1F6D2),
          (0x1F6D5, 0x1F6EC),
          (0x1F6F0, 0x1F6FC),
          (0x1F3D4, 0x1F3DF),
        ]),
        ..._symbols(const <int>[0x2600, 0x2601, 0x26C4, 0x26C5, 0x26EA, 0x26F2, 0x26F4, 0x26F5]),
      ]),
    ),
    EmojiCategoryData(
      key: EmojiCategoryKey.objects,
      label: '物品',
      icon: '💡',
      items: _dedupe(_ranges(const <(int, int)>[
        (0x1F4A1, 0x1F4FD),
        (0x1F50D, 0x1F5FA),
        (0x1F9E0, 0x1F9FF),
        (0x1FA70, 0x1FA7C),
        (0x1FA80, 0x1FA89),
        (0x1FA90, 0x1FAAC),
      ])),
    ),
    EmojiCategoryData(
      key: EmojiCategoryKey.symbols,
      label: '符号',
      icon: '❤️',
      items: _dedupe(<String>[
        ..._symbols(_intRange(0x2600, 0x26FF)),
        ..._symbols(_intRange(0x2700, 0x27BF)),
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '🩷', '🩵', '🩶',
        '0️⃣', '1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '#️⃣', '*️⃣',
        '©️', '®️', '™️', '〰️', '➰', '➿', '🔟', '🔠', '🔡', '🔢', '🔣', '🔤',
      ]),
    ),
    EmojiCategoryData(
      key: EmojiCategoryKey.flags,
      label: '旗帜',
      icon: '🇱🇰',
      items: _dedupe(<String>[
        '🏳️', '🏴', '🏁', '🚩', '🏳️‍🌈', '🏳️‍⚧️', '🏴‍☠️',
        ..._countryCodes.map(_flagForCode),
        _flagForCode('EU'),
        _flagForCode('UN'),
      ]),
    ),
  ];

  static final List<String> all = List<String>.unmodifiable(
    _dedupe(categories.expand((category) => category.items)),
  );
}

const List<String> _skinTones = <String>['🏻', '🏼', '🏽', '🏾', '🏿'];

List<String> _ranges(List<(int, int)> ranges) => <String>[
  for (final range in ranges)
    for (var codePoint = range.$1; codePoint <= range.$2; codePoint++)
      if (!_standaloneModifierCodePoints.contains(codePoint))
        String.fromCharCode(codePoint),
];

List<int> _intRange(int start, int end) => <int>[
  for (var value = start; value <= end; value++) value,
];

List<String> _symbols(List<int> codePoints) => <String>[
  for (final codePoint in codePoints) '${String.fromCharCode(codePoint)}\uFE0F',
];

List<String> _skinToneVariants(List<String> bases) => <String>[
  for (final base in bases) ...<String>[base, for (final tone in _skinTones) '$base$tone'],
];

List<String> _professionSequences() {
  const people = <String>['🧑', '👩', '👨'];
  const tools = <String>[
    '⚕️', '⚖️', '🌾', '🍳', '🎓', '🎤', '🏫', '🏭',
    '💻', '💼', '🔧', '🔬', '🎨', '🚒', '✈️', '🚀',
  ];
  return <String>[
    for (final person in people)
      for (final tool in tools) ...<String>[
        '$person\u200D$tool',
        for (final tone in _skinTones) '$person$tone\u200D$tool',
      ],
  ];
}

const List<String> _familySequences = <String>[
  '👨‍👩‍👦',
  '👨‍👩‍👧',
  '👨‍👩‍👧‍👦',
  '👨‍👩‍👦‍👦',
  '👨‍👩‍👧‍👧',
  '👩‍👩‍👦',
  '👩‍👩‍👧',
  '👩‍👩‍👧‍👦',
  '👩‍👩‍👦‍👦',
  '👩‍👩‍👧‍👧',
  '👨‍👨‍👦',
  '👨‍👨‍👧',
  '👨‍👨‍👧‍👦',
  '👨‍👨‍👦‍👦',
  '👨‍👨‍👧‍👧',
  '👩‍👦',
  '👩‍👧',
  '👩‍👧‍👦',
  '👩‍👦‍👦',
  '👩‍👧‍👧',
  '👨‍👦',
  '👨‍👧',
  '👨‍👧‍👦',
  '👨‍👦‍👦',
  '👨‍👧‍👧',
];

const Set<int> _standaloneModifierCodePoints = <int>{
  0x1F3FB,
  0x1F3FC,
  0x1F3FD,
  0x1F3FE,
  0x1F3FF,
};

List<String> _dedupe(Iterable<String> items) =>
    List<String>.unmodifiable(<String>{for (final item in items) if (item.isNotEmpty) item});

String _flagForCode(String code) {
  final normalized = code.toUpperCase();
  if (normalized.length != 2) return '';
  return normalized.codeUnits
      .map((unit) => String.fromCharCode(0x1F1E6 + unit - 0x41))
      .join();
}

const List<String> _countryCodes = <String>[
  'AC', 'AD', 'AE', 'AF', 'AG', 'AI', 'AL', 'AM', 'AO', 'AQ', 'AR', 'AS', 'AT', 'AU', 'AW', 'AX', 'AZ',
  'BA', 'BB', 'BD', 'BE', 'BF', 'BG', 'BH', 'BI', 'BJ', 'BL', 'BM', 'BN', 'BO', 'BQ', 'BR', 'BS', 'BT', 'BV', 'BW', 'BY', 'BZ',
  'CA', 'CC', 'CD', 'CF', 'CG', 'CH', 'CI', 'CK', 'CL', 'CM', 'CN', 'CO', 'CP', 'CR', 'CU', 'CV', 'CW', 'CX', 'CY', 'CZ',
  'DE', 'DG', 'DJ', 'DK', 'DM', 'DO', 'DZ', 'EA', 'EC', 'EE', 'EG', 'EH', 'ER', 'ES', 'ET',
  'FI', 'FJ', 'FK', 'FM', 'FO', 'FR', 'GA', 'GB', 'GD', 'GE', 'GF', 'GG', 'GH', 'GI', 'GL', 'GM', 'GN', 'GP', 'GQ', 'GR', 'GS', 'GT', 'GU', 'GW', 'GY',
  'HK', 'HM', 'HN', 'HR', 'HT', 'HU', 'IC', 'ID', 'IE', 'IL', 'IM', 'IN', 'IO', 'IQ', 'IR', 'IS', 'IT',
  'JE', 'JM', 'JO', 'JP', 'KE', 'KG', 'KH', 'KI', 'KM', 'KN', 'KP', 'KR', 'KW', 'KY', 'KZ',
  'LA', 'LB', 'LC', 'LI', 'LK', 'LR', 'LS', 'LT', 'LU', 'LV', 'LY',
  'MA', 'MC', 'MD', 'ME', 'MF', 'MG', 'MH', 'MK', 'ML', 'MM', 'MN', 'MO', 'MP', 'MQ', 'MR', 'MS', 'MT', 'MU', 'MV', 'MW', 'MX', 'MY', 'MZ',
  'NA', 'NC', 'NE', 'NF', 'NG', 'NI', 'NL', 'NO', 'NP', 'NR', 'NU', 'NZ',
  'OM', 'PA', 'PE', 'PF', 'PG', 'PH', 'PK', 'PL', 'PM', 'PN', 'PR', 'PS', 'PT', 'PW', 'PY',
  'QA', 'RE', 'RO', 'RS', 'RU', 'RW',
  'SA', 'SB', 'SC', 'SD', 'SE', 'SG', 'SH', 'SI', 'SJ', 'SK', 'SL', 'SM', 'SN', 'SO', 'SR', 'SS', 'ST', 'SV', 'SX', 'SY', 'SZ',
  'TA', 'TC', 'TD', 'TF', 'TG', 'TH', 'TJ', 'TK', 'TL', 'TM', 'TN', 'TO', 'TR', 'TT', 'TV', 'TW', 'TZ',
  'UA', 'UG', 'UM', 'US', 'UY', 'UZ', 'VA', 'VC', 'VE', 'VG', 'VI', 'VN', 'VU',
  'WF', 'WS', 'XK', 'YE', 'YT', 'ZA', 'ZM', 'ZW',
];
