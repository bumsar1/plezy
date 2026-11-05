import 'package:drift/drift.dart';

/// Schema-less drift database for study mode's dictionary files: they are
/// built offline or by the importer, so this only runs raw SQL against them.
class StudyDatabase extends GeneratedDatabase {
  StudyDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (_) async {}, onUpgrade: (_, _, _) async {});
}
