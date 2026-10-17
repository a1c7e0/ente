import "dart:async" show StreamSubscription;
import "dart:math";

import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/foundation.dart" show kDebugMode;
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/face/person.dart";
import 'package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart';
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_result.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/viewer/people/cluster_page.dart";
import "package:photos/ui/viewer/people/face_thumbnail_squircle.dart";
import "package:photos/ui/viewer/people/merge_clusters_to_person_sheet.dart";
import "package:photos/ui/viewer/people/person_clusters_page.dart";
import "package:photos/ui/viewer/people/review_thumbnail.dart";
import "package:photos/ui/viewer/people/review_thumbnail_loader.dart";
import "package:photos/ui/viewer/people/save_or_edit_person.dart";
import "package:photos/utils/dialog_util.dart";

class SuggestionUserFeedback {
  final bool accepted;
  final ClusterSuggestion suggestion;

  SuggestionUserFeedback(this.accepted, this.suggestion);
}

class PersonReviewClusterSuggestion extends StatefulWidget {
  final PersonEntity person;

  const PersonReviewClusterSuggestion(this.person, {super.key});

  @override
  State<PersonReviewClusterSuggestion> createState() => _PersonClustersState();
}

class _PersonClustersState extends State<PersonReviewClusterSuggestion> {
  int currentSuggestionIndex = 0;
  Key futureBuilderKeySuggestions = UniqueKey();
  bool canGiveFeedback = false;
  final _thumbnailLoader = ReviewThumbnailLoader(
    6,
    prefetchGroups: 5,
    prefetchImageBudget: 8,
  );
  ReviewThumbnails _currentThumbnails = {};
  int _suggestionLoadID = 0;
  bool _restoringSuggestion = false;
  List<SuggestionUserFeedback> pastUserFeedback = [];
  List<ClusterSuggestion> allSuggestions = [];
  late final Logger _logger = Logger('_PersonClustersState');
  late final mlDataDB = MLDataDB.instance;

  late Future<List<ClusterSuggestion>> futureClusterSuggestions;
  StreamSubscription<PeopleChangedEvent>? _peopleChangedEvent;

  @override
  void initState() {
    super.initState();
    _fetchClusterSuggestions();
  }

  @override
  void dispose() {
    _suggestionLoadID++;
    _thumbnailLoader.dispose();
    _peopleChangedEvent?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.strings.reviewSuggestions),
        actions: [
          if (pastUserFeedback.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo_outlined),
              onPressed: canGiveFeedback ? _undoLastFeedback : null,
            ),
          IconButton(
            icon: const Icon(Icons.history_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => PersonClustersPage(widget.person),
                ),
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<List<ClusterSuggestion>>(
        key: futureBuilderKeySuggestions,
        future: futureClusterSuggestions,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            if (snapshot.data!.isEmpty) {
              _peopleChangedEvent?.cancel();
              _peopleChangedEvent = null;
              return Center(
                child: Text(
                  context.strings.noSuggestionsForPerson(
                    personName: widget.person.data.name,
                  ),
                  style: getEnteTextTheme(context).largeMuted,
                ),
              );
            }

            allSuggestions = snapshot.data!;
            final numberOfDifferentSuggestions = allSuggestions.length;
            final currentSuggestion = allSuggestions[currentSuggestionIndex];
            final String clusterID = currentSuggestion.clusterIDToMerge;
            final double distance = currentSuggestion.distancePersonToCluster;
            final bool usingMean = currentSuggestion.usedOnlyMeanForSuggestion;
            final List<EnteFile> files = currentSuggestion.filesInCluster;

            _peopleChangedEvent?.cancel();
            _peopleChangedEvent = Bus.instance.on<PeopleChangedEvent>().listen((
              event,
            ) {
              if (event.source == clusterID.toString()) {
                if (event.type == PeopleEventType.removedFilesFromCluster) {
                  for (var updatedFile in event.relevantFiles!) {
                    files.remove(updatedFile);
                  }
                  setState(() {});
                }
                if (event.type == PeopleEventType.removedFaceFromCluster) {
                  for (final String removedFaceID in event.relevantFaceIDs!) {
                    final int fileID = getFileIdFromFaceId<int>(removedFaceID);
                    files.removeWhere((file) => file.uploadedFileID == fileID);
                  }
                  setState(() {});
                }
              }
            });

            return Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: GestureDetector(
                      onTap: () {
                        final List<EnteFile> sortedFiles = List<EnteFile>.from(
                          currentSuggestion.filesInCluster,
                        );
                        sortedFiles.sort(
                          (a, b) => b.creationTime!.compareTo(a.creationTime!),
                        );
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => ClusterPage(
                              sortedFiles,
                              personID: widget.person,
                              clusterID: clusterID,
                              showNamingBanner: false,
                            ),
                          ),
                        );
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 20,
                        ),
                        child: _buildSuggestionView(
                          clusterID,
                          distance,
                          usingMean,
                          files,
                          numberOfDifferentSuggestions,
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: 12.0,
                      right: 12.0,
                      bottom: 48,
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: context.componentColors.warning,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    Radii.button,
                                  ),
                                ),
                                child: ButtonComponent(
                                  variant:
                                      ButtonComponentVariant.tertiaryCritical,
                                  leading: const Icon(Icons.close),
                                  label: context.strings.no,
                                  onTap: () => _handleUserClusterChoice(
                                    clusterID,
                                    false,
                                    numberOfDifferentSuggestions,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12.0),
                            Expanded(
                              child: ButtonComponent(
                                label: context.strings.yes,
                                onTap: () => _handleUserClusterChoice(
                                  clusterID,
                                  true,
                                  numberOfDifferentSuggestions,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _saveAsAnotherPerson(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 32,
                            ),
                            child: Text(
                              context.strings.saveAsAnotherPerson,
                              style: getEnteTextTheme(context).mini.copyWith(
                                color: getEnteColorScheme(context).textMuted,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          } else if (snapshot.hasError) {
            _logger.severe(
              "Error fetching suggestions",
              snapshot.error!,
              snapshot.stackTrace,
            );
            return Center(
              child: TextButton.icon(
                onPressed: () {
                  _thumbnailLoader.retryFailures();
                  if (allSuggestions.isEmpty) {
                    setState(() {
                      futureBuilderKeySuggestions = UniqueKey();
                      _fetchClusterSuggestions();
                    });
                  } else {
                    _prepareNextSuggestion();
                  }
                },
                icon: const Icon(Icons.refresh),
                label: Text(context.strings.retry),
              ),
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }

  Future<void> _handleUserClusterChoice(
    String clusterID,
    bool yesOrNo,
    int numberOfSuggestions,
  ) async {
    if (!canGiveFeedback) return;
    final suggestion = allSuggestions[currentSuggestionIndex];
    setState(() => canGiveFeedback = false);
    try {
      if (yesOrNo) {
        await ClusterFeedbackService.instance.addClusterToExistingPerson(
          person: widget.person,
          clusterID: clusterID,
        );
      } else {
        await ClusterFeedbackService.instance.rejectSuggestion(
          personID: widget.person.remoteID,
          clusterID: clusterID,
        );
      }
      if (!mounted) return;
      pastUserFeedback.add(SuggestionUserFeedback(yesOrNo, suggestion));
      _notifySuggestionReviewed();
      if (yesOrNo) currentSuggestionIndex++;
      if (!yesOrNo || currentSuggestionIndex >= numberOfSuggestions) {
        setState(() {
          currentSuggestionIndex = 0;
          futureBuilderKeySuggestions = UniqueKey();
          _fetchClusterSuggestions();
        });
      } else {
        _prepareNextSuggestion();
      }
    } catch (error, stack) {
      _logger.severe("Error saving review feedback", error, stack);
      if (!mounted) return;
      setState(() => canGiveFeedback = true);
      await showGenericErrorDialog(context: context, error: error);
    }
  }

  void _notifySuggestionReviewed() {
    Bus.instance.fire(
      PeopleChangedEvent(
        person: widget.person,
        type: PeopleEventType.reviewedSuggestion,
        source: runtimeType.toString(),
      ),
    );
  }

  Future<void> _saveAsAnotherPerson() async {
    if (!canGiveFeedback ||
        allSuggestions.isEmpty ||
        currentSuggestionIndex >= allSuggestions.length) {
      return;
    }

    try {
      final currentSuggestion = allSuggestions[currentSuggestionIndex];
      final clusterID = currentSuggestion.clusterIDToMerge;
      final someFile = currentSuggestion.filesInCluster.first;

      final result = isBodyReference(clusterID)
          ? await showMergeClustersToPersonPage(context)
          : await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => SaveOrEditPerson(
                  clusterID,
                  file: someFile,
                  isEditing: false,
                ),
              ),
            );
      if (result is MergePersonSelectionResult) {
        final selected =
            result.person ??
            await PersonService.instance.getPerson(result.personId);
        if (selected == null) return;
        if (selected.remoteID != currentSuggestion.person.remoteID) {
          await ClusterFeedbackService.instance.rejectSuggestion(
            personID: currentSuggestion.person.remoteID,
            clusterID: clusterID,
          );
        }
        await ClusterFeedbackService.instance.addClusterToExistingPerson(
          person: selected,
          clusterID: clusterID,
        );
      }
      if (result == null || result == false) {
        return;
      }
      _notifySuggestionReviewed();
      if (!mounted) return;
      currentSuggestionIndex++;
      final numberOfSuggestions = allSuggestions.length;
      if (currentSuggestionIndex >= numberOfSuggestions) {
        setState(() {
          currentSuggestionIndex = 0;
          futureBuilderKeySuggestions = UniqueKey();
          _fetchClusterSuggestions();
        });
      } else {
        _prepareNextSuggestion();
      }
    } catch (e, s) {
      _logger.severe("Error saving as another person", e, s);
    }
  }

  void _fetchClusterSuggestions() {
    canGiveFeedback = false;
    final loadID = ++_suggestionLoadID;
    futureClusterSuggestions = ClusterFeedbackService.instance
        .getSuggestionForPerson(widget.person)
        .then((suggestions) {
          if (!mounted || loadID != _suggestionLoadID) {
            return <ClusterSuggestion>[];
          }
          allSuggestions = suggestions;
          return _prepareSuggestions(suggestions, 0, loadID);
        });
  }

  Future<List<ClusterSuggestion>> _prepareSuggestions(
    List<ClusterSuggestion> suggestions,
    int index,
    int loadID, {
    bool forceFirst = false,
  }) async {
    if (suggestions.isEmpty) {
      if (mounted && loadID == _suggestionLoadID) {
        _thumbnailLoader.prefetch(const []);
        canGiveFeedback = true;
      }
      return suggestions;
    }
    final candidates = suggestions.skip(index);
    final prepared = await _thumbnailLoader.next(
      forceFirst ? candidates.take(1) : candidates,
    );
    if (!mounted || loadID != _suggestionLoadID || prepared == null) return [];
    final selectedIndex = suggestions.indexOf(prepared.suggestion, index);
    final selected = suggestions.removeAt(selectedIndex);
    suggestions.insert(index, selected);
    _currentThumbnails = prepared.thumbnails;
    canGiveFeedback = true;
    _restoringSuggestion = false;
    _thumbnailLoader.prefetch(suggestions.skip(index + 1));
    return suggestions;
  }

  void _prepareNextSuggestion() {
    canGiveFeedback = false;
    final loadID = ++_suggestionLoadID;
    setState(() {
      futureBuilderKeySuggestions = UniqueKey();
      futureClusterSuggestions = _prepareSuggestions(
        allSuggestions,
        currentSuggestionIndex,
        loadID,
        forceFirst: _restoringSuggestion,
      );
    });
  }

  Widget _buildSuggestionView(
    String clusterID,
    double distance,
    bool usingMean,
    List<EnteFile> files,
    int numberOfSuggestions,
  ) {
    final widgetToReturn = Column(
      key: ValueKey("cluster_id-$clusterID-files-${files.length}"),
      children: <Widget>[
        if (kDebugMode)
          Text(
            "ClusterID: $clusterID, Distance: ${distance.toStringAsFixed(3)}, usingMean: $usingMean",
            style: getEnteTextTheme(context).smallMuted,
          ),
        Text(
          "${widget.person.data.name}?",
          style: getEnteTextTheme(context).largeMuted,
        ),
        const SizedBox(height: 24),
        _buildThumbnailWidget(files, clusterID),
        const SizedBox(height: 24.0),
      ],
    );
    return widgetToReturn;
  }

  Widget _buildThumbnailWidget(List<EnteFile> files, String clusterID) {
    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: _buildThumbnailWidgetsRow(
            files,
            clusterID,
            _currentThumbnails,
          ),
        ),
        if (files.length > 3) const SizedBox(height: 12),
        if (files.length > 3)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: _buildThumbnailWidgetsRow(
              files,
              clusterID,
              _currentThumbnails,
              start: 3,
            ),
          ),
      ],
    );
  }

  List<Widget> _buildThumbnailWidgetsRow(
    List<EnteFile> files,
    String cluserId,
    ReviewThumbnails faceThumbnails, {
    int start = 0,
  }) {
    return List<Widget>.generate(
      min(3, max(0, files.length - start)),
      (index) => Padding(
        padding: const EdgeInsets.all(8.0),
        child: SizedBox(
          width: 100,
          height: 100,
          child: Stack(
            children: [
              FaceThumbnailSquircleClip(
                child: ReviewThumbnailWidget(
                  faceThumbnails[files[start + index].uploadedFileID!]!,
                  key: ValueKey((
                    cluserId,
                    files[start + index].uploadedFileID,
                  )),
                ),
              ),
              if (start + index == 5 && files.length > 6)
                FaceThumbnailSquircleClip(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                    ),
                    child: Center(
                      child: Text(
                        '+${files.length - 5}',
                        style: darkTheme.textTheme.h3Bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _undoLastFeedback() async {
    if (!canGiveFeedback || pastUserFeedback.isEmpty) return;
    setState(() => canGiveFeedback = false);
    final lastFeedback = pastUserFeedback.last;
    try {
      if (isBodyReference(lastFeedback.suggestion.clusterIDToMerge)) {
        await ClusterFeedbackService.instance.undoSuggestion(
          widget.person,
          lastFeedback.suggestion.clusterIDToMerge,
        );
      } else if (lastFeedback.accepted) {
        await PersonService.instance.removeClusterToPerson(
          personID: widget.person.remoteID,
          clusterID: lastFeedback.suggestion.clusterIDToMerge,
        );
      } else {
        await ClusterFeedbackService.instance.undoSuggestion(
          widget.person,
          lastFeedback.suggestion.clusterIDToMerge,
        );
      }
      if (!mounted) return;
      pastUserFeedback.removeLast();
      _notifySuggestionReviewed();
      final loadID = ++_suggestionLoadID;
      final remaining = allSuggestions.sublist(currentSuggestionIndex)
        ..insert(0, lastFeedback.suggestion);
      allSuggestions = remaining;
      currentSuggestionIndex = 0;
      _restoringSuggestion = true;
      futureClusterSuggestions = _prepareSuggestions(
        remaining,
        0,
        loadID,
        forceFirst: true,
      );
      futureBuilderKeySuggestions = UniqueKey();
      setState(() {});
    } catch (error, stack) {
      _logger.severe("Error undoing review feedback", error, stack);
      if (!mounted) return;
      setState(() => canGiveFeedback = true);
      await showGenericErrorDialog(context: context, error: error);
    }
  }
}
