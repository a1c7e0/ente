import "package:flutter/material.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/services/machine_learning/semantic_search/semantic_search_service.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/utils/dialog_util.dart";

Future<void> purgeEmptyMLIndices(BuildContext context) async {
  try {
    final Set<int> emptyFileIDs = await MLDataDB.instance.getErroredFileIDs();
    await MLDataDB.instance.deleteFaceIndexForFiles(emptyFileIDs.toList());
    await MLDataDB.instance.deleteClipEmbeddings(emptyFileIDs.toList());
    if (!context.mounted) return;
    showShortToast(context, "Deleted ${emptyFileIDs.length} entries");
  } catch (e) {
    if (!context.mounted) return;
    // ignore: unawaited_futures
    showGenericErrorDialog(context: context, error: e);
  }
}

Future<void> resetAllLocalML(BuildContext context) async {
  try {
    await MLDataDB.instance.dropClustersAndPersonTable(faces: true);
    await SemanticSearchService.instance.clearIndexes();
    Bus.instance.fire(PeopleChangedEvent());
    if (!context.mounted) return;
    showShortToast(context, "All local ML cleared");
  } catch (e) {
    if (!context.mounted) return;
    // ignore: unawaited_futures
    showGenericErrorDialog(context: context, error: e);
  }
}
