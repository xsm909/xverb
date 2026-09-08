import 'vfs_path.dart';

/// What a directory entry actually is.
enum FileKind { file, directory, link, unknown }

/// One row in a panel: a file, directory or link listed by a provider.
class FileEntry {
  const FileEntry({
    required this.path,
    required this.name,
    required this.kind,
    this.size = 0,
    this.modified,
    this.isHidden = false,
    this.linkTarget,
    this.isParentLink = false,
  });

  /// The synthetic `..` row that walks one level up.
  factory FileEntry.parentLink(VfsPath parent) => FileEntry(
        path: parent,
        name: '..',
        kind: FileKind.directory,
        isParentLink: true,
      );

  final VfsPath path;
  final String name;
  final FileKind kind;
  final int size;
  final DateTime? modified;
  final bool isHidden;
  final String? linkTarget;

  /// True only for the `..` row, which is never selectable or deletable.
  final bool isParentLink;

  bool get isDirectory => kind == FileKind.directory;

  /// True for a symbolic link, whatever it points at. [kind] describes the
  /// target so the entry behaves like what it resolves to, which leaves this
  /// as the only place the link itself is still visible.
  bool get isLink => linkTarget != null || kind == FileKind.link;

  /// Extension without the leading dot, lower-cased. Empty for directories
  /// and for dotfiles such as `.gitignore`, which have no extension.
  String get extension => isDirectory ? '' : extensionOf(name);

  /// The same rule on a name nobody has listed yet — the one being typed into
  /// "pack into", which has to be understood before there is a file to stat.
  ///
  /// One function so the two answers cannot drift: whatever decides that
  /// `box.zip` on disk is entered as a folder is what decides that a new
  /// `box.zip` is written as one.
  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// What this file *is*, for choosing what opens it.
  ///
  /// [extension] with one addition: a name that is nothing but a dot and a
  /// word — `.gitignore`, `.gitattributes`, `.editorconfig` — is that word.
  /// Every editor treats those as a type, and until this existed they had no
  /// type at all, so F3 on a `.gitignore` fell through every viewer that
  /// claims something and landed on the hex dump.
  ///
  /// Separate from [extension] rather than folded into it, because the two
  /// questions are different: the listing shows `.gitignore` as a name with no
  /// extension, which is what it looks like, and sorting by extension must not
  /// file it under G.
  String get typeName {
    final ext = extension;
    if (ext.isNotEmpty) return ext;
    if (isDirectory || name.length < 2 || !name.startsWith('.')) return '';
    final rest = name.substring(1);
    return rest.contains('.') ? '' : rest.toLowerCase();
  }

  /// File name without its extension.
  String get baseName {
    final ext = extension;
    if (ext.isEmpty) return name;
    return name.substring(0, name.length - ext.length - 1);
  }

  /// Builds an entry from the map a plugin returns over RPC.
  factory FileEntry.fromJson(Map<String, dynamic> json, VfsPath directory) {
    final name = json['name'] as String;
    final modifiedMs = json['modified'];
    return FileEntry(
      path: directory.child(name),
      name: name,
      kind: _kindFromString(json['kind'] as String?),
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: modifiedMs is num
          ? DateTime.fromMillisecondsSinceEpoch(modifiedMs.toInt())
          : null,
      isHidden: json['hidden'] as bool? ?? name.startsWith('.'),
      linkTarget: json['target'] as String?,
    );
  }

  static FileKind _kindFromString(String? value) => switch (value) {
        'dir' || 'directory' => FileKind.directory,
        'file' => FileKind.file,
        'link' => FileKind.link,
        _ => FileKind.unknown,
      };
}
