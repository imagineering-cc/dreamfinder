/// Unified query facade for the Dreamfinder domain tables.
///
/// All functions are synchronous (sqlite3 is sync). Domain logic is
/// organized into mixins in `queries/` — this file composes them into
/// a single [Queries] class for convenience.
library;

import '../memory/embedding_pipeline.dart';
import 'database.dart';
import 'queries/board_config_queries.dart';
import 'queries/calendar_queries.dart';
import 'queries/dream_queries.dart';
import 'queries/identity_queries.dart';
import 'queries/memory_queries.dart';
import 'queries/metadata_queries.dart';
import 'queries/oauth_queries.dart';
import 'queries/reminder_queries.dart';
import 'queries/standup_queries.dart';
import 'queries/user_link_queries.dart';
import 'queries/workspace_queries.dart';

export 'queries/board_config_queries.dart';
export 'queries/calendar_queries.dart';
export 'queries/dream_queries.dart';
export 'queries/identity_queries.dart';
export 'queries/memory_queries.dart';
export 'queries/metadata_queries.dart';
export 'queries/oauth_queries.dart';
export 'queries/reminder_queries.dart';
export 'queries/standup_queries.dart';
export 'queries/user_link_queries.dart';
export 'queries/workspace_queries.dart';

/// Repository of query functions for the domain tables.
///
/// Constructed with a [BotDatabase] so tests can inject an in-memory instance.
/// Domain-specific methods are provided by the mixins mixed into this class.
class Queries
    with
        WorkspaceQueries,
        UserLinkQueries,
        BoardConfigQueries,
        ReminderQueries,
        IdentityQueries,
        OAuthQueries,
        MemoryQueries,
        MetadataQueries,
        StandupQueries,
        CalendarQueries,
        DreamQueries
    implements MemoryQueryAccessor {
  Queries(this.db);

  @override
  final BotDatabase db;
}
