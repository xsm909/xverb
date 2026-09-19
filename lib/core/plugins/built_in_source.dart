/// The collection the app knows about without being told. A constant rather
/// than a stored setting, so it cannot be lost and needs no migration.
///
/// In `core` rather than beside the plugin manager, because the first run's
/// offer on the About card installs from it too — see `FirstRunSetup`.
const String kBuiltInPluginSource = 'xsm909/xverb-plugins';
